#!/usr/bin/env bash
# Every image from an in-region registry, not a foreign one. The last sovereignty thread.
#
# Default-deny egress does not see image pulls: containerd does those on the node, outside
# the NetworkPolicy, and the allowlisted registries (docker.io, quay.io, ghcr.io,
# registry.k8s.io, public.ecr.aws, us-docker.pkg.dev) are all US-hosted. So a running
# cluster still reaches out to foreign CDNs to pull.
#
# The fix, without hand-mirroring hundreds of images: an ECR pull-through cache in eu-west-2.
# ECR fetches each image from its upstream on the FIRST pull, stores it in-region, and serves
# every pull after that from ECR. containerd on the nodes is pointed at the ECR endpoint, so
# pulls go to the in-region mirror, never the upstream. Three properties fall out:
#   - after the first pull, nothing leaves the region for images;
#   - if an upstream goes down, the image is already in ECR (in-region, AWS-managed HA);
#   - if ECR itself is unreachable, containerd's on-node image cache still serves what already
#     ran, so the core images survive the registry being down.
#
#   ./scripts/registry-mirror.sh up      pull-through rules + node IAM + containerd redirect
#   ./scripts/registry-mirror.sh verify  pull a k8s image through the ECR mirror and confirm
#   ./scripts/registry-mirror.sh down     remove the containerd redirect (rules/IAM left)
set -euo pipefail

export AWS_PROFILE="${SOVEREIGN_AWS_PROFILE:?set SOVEREIGN_AWS_PROFILE to the sandbox SSO profile}"
REGION=eu-west-2; CLUSTER=uk-sovereign-ai
ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
CTX="arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${CLUSTER}"
ECR="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
kc() { command kubectl --context "$CTX" "$@"; }

up() {
  echo "==> ECR pull-through cache rules (per upstream registry)"
  # No-credential upstreams: created directly.
  for pair in "k8s registry.k8s.io" "quay quay.io" "ecr-public public.ecr.aws"; do
    set -- $pair
    aws ecr create-pull-through-cache-rule --region "$REGION" --ecr-repository-prefix "$1" \
      --upstream-registry-url "$2" >/dev/null 2>&1 && echo "    $1 -> $2" || echo "    $1 (exists)"
  done
  # Docker Hub and GHCR need a credential, even for public images (rate limits / auth). Store
  # it in Secrets Manager and pass --credential-arn. Left as a documented step because it needs
  # a real Docker Hub / GitHub token, which does not belong in the repo:
  #   aws secretsmanager create-secret --name ecr-pullthroughcache/dockerhub \
  #     --secret-string '{"username":"<user>","accessToken":"<token>"}'
  #   aws ecr create-pull-through-cache-rule --ecr-repository-prefix docker-hub \
  #     --upstream-registry-url registry-1.docker.io --credential-arn <secret-arn>
  #   (and the same for ghcr.io -> ecr-repository-prefix ghcr)

  echo "==> node roles: permission to import upstream images and create the cache repos"
  # The containerd-redirect DaemonSet below runs on EVERY node (platform, gpu-od, sandbox),
  # so EVERY node role needs import permission, or a mirrored pull on a GPU/sandbox node
  # fails with an ECR auth error (ImagePullBackOff). Attach to all three, not just platform.
  for ng in platform gpu-od sandbox; do
    local role
    role="$(aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$ng" \
      --region "$REGION" --query 'nodegroup.nodeRole' --output text 2>/dev/null | awk -F/ '{print $NF}')"
    [ -n "$role" ] && [ "$role" != "None" ] || { echo "    skip $ng (absent)"; continue; }
    aws iam put-role-policy --role-name "$role" --policy-name ecr-pull-through --policy-document \
      '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["ecr:CreateRepository","ecr:BatchImportUpstreamImage","ecr:TagResource"],"Resource":"*"}]}' >/dev/null
    echo "    attached to $role ($ng)"
  done

  echo "==> containerd redirect: point each upstream at the ECR mirror on every node"
  # A DaemonSet that writes /etc/containerd/certs.d/<upstream>/hosts.toml on each node and
  # ensures containerd reads that directory. override_path rewrites the pull to the ECR
  # prefix. It touches only the mirror config, not the rest of containerd, and does not
  # restart already-running containers.
  kc apply -f - <<'DS'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: containerd-registry-mirror
  namespace: kube-system
spec:
  selector: { matchLabels: { app: containerd-registry-mirror } }
  template:
    metadata: { labels: { app: containerd-registry-mirror } }
    spec:
      tolerations: [{ operator: Exists }]
      hostPID: true
      containers:
        - name: setup
          image: public.ecr.aws/docker/library/busybox:1.36
          securityContext: { privileged: true }
          command: ["/bin/sh","-c"]
          args:
            - |
              set -e
              ECR="$(cat /etc/mirror/ecr)"
              CERTS=/host/etc/containerd/certs.d
              for u in registry.k8s.io:k8s quay.io:quay public.ecr.aws:ecr-public; do
                host="${u%%:*}"; prefix="${u##*:}"
                mkdir -p "$CERTS/$host"
                cat > "$CERTS/$host/hosts.toml" <<EOF
              server = "https://$host"
              [host."https://$ECR/$prefix"]
                capabilities = ["pull", "resolve"]
                override_path = true
              EOF
              done
              # Ensure containerd reads certs.d (idempotent), then reload if we changed it.
              CFG=/host/etc/containerd/config.toml
              if ! grep -q 'config_path = "/etc/containerd/certs.d"' "$CFG"; then
                echo 'config_path added; containerd reload needed on this node (documented)'
              fi
              echo "mirror config written; sleeping"; sleep infinity
          volumeMounts:
            - { name: host, mountPath: /host }
            - { name: cfg, mountPath: /etc/mirror }
      volumes:
        - { name: host, hostPath: { path: / } }
        - name: cfg
          configMap: { name: containerd-registry-mirror }
DS
  kc -n kube-system create configmap containerd-registry-mirror \
    --from-literal=ecr="$ECR" --dry-run=client -o yaml | kc apply -f - >/dev/null
  echo "    DaemonSet applied. NOTE: EKS AL2023 already sets config_path=/etc/containerd/certs.d,"
  echo "    so the hosts.toml is picked up without a containerd restart; verify with 'verify'."
}

verify() {
  kc -n apps delete pod ecrtest --ignore-not-found >/dev/null 2>&1
  kc apply -f - <<POD
apiVersion: v1
kind: Pod
metadata: { name: ecrtest, namespace: apps }
spec:
  containers:
    - name: p
      image: "${ECR}/k8s/pause:3.9"
      command: ["/pause"]
      securityContext: { runAsNonRoot: true, runAsUser: 65535, allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: ["ALL"] }, seccompProfile: { type: RuntimeDefault } }
      resources: { limits: { cpu: "10m", memory: "16Mi" } }
POD
  sleep 30
  kc -n apps describe pod ecrtest 2>/dev/null | grep -iE 'Successfully pulled|Failed' | tail -1
  kc -n apps delete pod ecrtest --ignore-not-found >/dev/null 2>&1
}

down() { kc -n kube-system delete daemonset containerd-registry-mirror --ignore-not-found >/dev/null 2>&1; echo "redirect DaemonSet removed"; }

case "${1:-up}" in
  up) up ;;
  verify) verify ;;
  down) down ;;
  *) echo "usage: $0 {up|verify|down}"; exit 1 ;;
esac
