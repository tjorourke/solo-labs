#!/usr/bin/env bash
# The whole environment, from an empty AWS account to a defended, sovereign model with
# agents, in one command. Infrastructure as code end to end: the cluster and all three
# node groups are the eksctl config, everything above is versioned YAML and Helm values,
# and this script runs the layers in the one order that works.
#
#   SOVEREIGN_AWS_PROFILE=<profile> SOVEREIGN_ENV_FILE=<licences.env> ./deploy-all.sh
#   ./deploy-all.sh <phase>        run a single phase (see the list below)
#   ./deploy-all.sh phases         list the phases
#
# Nothing secret lives in the repo. The AWS account id and the weights bucket are derived
# at run time from the profile in effect, and the Solo licence keys are read from your
# environment (or SOVEREIGN_ENV_FILE), never committed.
#
# Every phase is idempotent, so a re-run after a failure picks up rather than starting
# again. The GPU meter ($5.84/hr) starts in the 'model' phase; everything before it is cheap.
#
# ---- the ordering constraints that make a from-zero rebuild succeed ----
# These are the traps that a hand-assembled cluster hides and a clean rebuild exposes:
#   * yaml/01 (the cluster-default StorageClass) must exist BEFORE Vault raft and the
#     kagent / agentregistry / management postgres, or their PVCs sit Pending forever.
#   * ambient.sh up (Istio base + istiod + cni + ztunnel) must run BEFORE istio-csr.sh,
#     which only rewires an existing mesh onto the Vault CA; without it there are no Istio
#     CRDs and no ztunnel to rewire.
#   * agentgateway.sh route (which applies yaml/30 and provisions the NLB) must run BEFORE
#     tls.sh up, which needs the NLB hostname to exist to issue the edge certificate.
#   * the model-door policies (yaml/32 JWT, 34 PII, 38 rate-limit) need the Gateway (30)
#     AND Keycloak up; the UI routes (46/47) must be live so keycloak.sovereign.local
#     resolves through the gateway before kagent / agentregistry / management validate
#     tokens against https://keycloak.sovereign.local.
#   * the mesh-dependent policies (yaml/33 model netpol, 48 egress waypoint, 49 agent
#     model route, 81 mesh PodMonitors) must run AFTER ambient.sh enrol.
#   * yaml/42 (agent admission) matches kagent CRDs, so it must run AFTER kagent.sh up.
set -euo pipefail

export SOVEREIGN_AWS_PROFILE="${SOVEREIGN_AWS_PROFILE:?set SOVEREIGN_AWS_PROFILE to your AWS SSO profile}"
export AWS_PROFILE="$SOVEREIGN_AWS_PROFILE"
REGION=eu-west-2
CLUSTER=uk-sovereign-ai
LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$LAB"

ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
[ -n "$ACCOUNT" ] && [ "$ACCOUNT" != "None" ] || { echo "error: no AWS identity; check SOVEREIGN_AWS_PROFILE (SSO login expired?)" >&2; exit 1; }
CTX="arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${CLUSTER}"

banner() { echo; echo "════════ $* ════════"; }
kc()     { command kubectl --context "$CTX" "$@"; }
ya()     { echo "  apply yaml/$1"; kc apply -f "yaml/$1"; }               # apply a yaml/ file
ensure_ns() { kc create namespace "$1" --dry-run=client -o yaml | kc apply -f - >/dev/null; }

# ---- phases, in order ----
# The three KMS keys the lab pins to: the EKS secrets envelope, the Vault auto-unseal key,
# and the cosign provenance key. They are account-level, so they survive a cluster teardown;
# on a fresh account they do not exist yet, so create them here (idempotent). vault.sh and
# yaml/41 reference the unseal and cosign keys BY ALIAS, so those resolve on their own; only
# the secrets key ARN has to be substituted into the eksctl config, which has a placeholder
# so the account id and key id never live in the repo.
ensure_kms() {
  for a in uk-sovereign-ai-secrets uk-sovereign-ai-vault-unseal uk-sovereign-ai-cosign; do
    if aws kms describe-key --key-id "alias/$a" --region "$REGION" >/dev/null 2>&1; then
      echo "  KMS alias/$a exists"
    else
      echo "  creating KMS key alias/$a"
      local kid; kid=$(aws kms create-key --region "$REGION" --description "sovereign-ai $a" \
        --query 'KeyMetadata.KeyId' --output text)
      aws kms create-alias --region "$REGION" --alias-name "alias/$a" --target-key-id "$kid"
    fi
  done
}

# Render eks/cluster.yaml with the real, in-region secrets-CMK ARN in place of the
# placeholder, to a temp file eksctl consumes. The repo copy keeps the placeholder.
render_cluster_yaml() {
  local skey; skey=$(aws kms describe-key --key-id alias/uk-sovereign-ai-secrets \
    --region "$REGION" --query 'KeyMetadata.Arn' --output text)
  [ -n "$skey" ] || { echo "error: cannot resolve alias/uk-sovereign-ai-secrets" >&2; return 1; }
  sed "s|arn:aws:kms:eu-west-2:<AWS_ACCOUNT_ID>:key/<secrets-cmk>|${skey}|" \
    eks/cluster.yaml > /tmp/sovereign-cluster.yaml
  echo /tmp/sovereign-cluster.yaml
}

p_cluster() {
  banner "cluster: KMS keys, VPC, and all three node groups (platform, gpu-od, sandbox)"
  ensure_kms
  local cfg; cfg="$(render_cluster_yaml)"
  # Read the STATUS, not just existence: right after a teardown the cluster lingers in
  # DELETING and a bare describe still succeeds, which would wrongly take the "exists" branch
  # and run `create nodegroup` (which rejects cluster-level fields like publicAccessCIDRs).
  local status
  status="$(aws eks describe-cluster --region "$REGION" --name "$CLUSTER" --query 'cluster.status' --output text 2>/dev/null || echo NONE)"
  while [ "$status" = "DELETING" ]; do
    echo "  a cluster of this name is still DELETING; waiting 30s..."
    sleep 30
    status="$(aws eks describe-cluster --region "$REGION" --name "$CLUSTER" --query 'cluster.status' --output text 2>/dev/null || echo NONE)"
  done
  # The EKS cluster leaves the EKS API before its CloudFormation stack (VPC, subnets, NAT)
  # finishes deleting; eksctl create then fails with AlreadyExists on that stack. If we are
  # about to create, wait for the old stack to be fully gone first.
  if [ "$status" != "ACTIVE" ]; then
    local st
    st="$(aws cloudformation describe-stacks --region "$REGION" --stack-name "eksctl-${CLUSTER}-cluster" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo NONE)"
    while [ "$st" = "DELETE_IN_PROGRESS" ]; do
      echo "  the previous cluster's CloudFormation stack is still deleting; waiting 30s..."
      sleep 30
      st="$(aws cloudformation describe-stacks --region "$REGION" --stack-name "eksctl-${CLUSTER}-cluster" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo NONE)"
    done
    # If it is stuck DELETE_FAILED (a VPC dependency a teardown missed — a k8s-created load
    # balancer or security group), retry the delete once, then wait it out again.
    if [ "$st" = "DELETE_FAILED" ]; then
      echo "  previous cluster stack is DELETE_FAILED; retrying the delete once"
      aws cloudformation delete-stack --region "$REGION" --stack-name "eksctl-${CLUSTER}-cluster" >/dev/null 2>&1 || true
      sleep 15
      st="$(aws cloudformation describe-stacks --region "$REGION" --stack-name "eksctl-${CLUSTER}-cluster" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo NONE)"
      while [ "$st" = "DELETE_IN_PROGRESS" ]; do sleep 30; st="$(aws cloudformation describe-stacks --region "$REGION" --stack-name "eksctl-${CLUSTER}-cluster" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo NONE)"; done
    fi
    [ "$st" = "DELETE_FAILED" ] && { echo "error: cluster stack still DELETE_FAILED. Clear its leftover VPC dependencies (ELBs, non-default security groups) by hand, then re-run." >&2; exit 1; }
  fi
  if [ "$status" = "ACTIVE" ]; then
    echo "cluster exists and is ACTIVE; ensuring node groups"
    for ng in platform gpu-od sandbox; do
      aws eks describe-nodegroup --region "$REGION" --cluster-name "$CLUSTER" --nodegroup-name "$ng" >/dev/null 2>&1 \
        || eksctl create nodegroup -f "$cfg" --include="$ng"
    done
  else
    eksctl create cluster -f "$cfg"
  fi
}

p_model() {
  banner "model: network policy, storage, the default StorageClass, IRSA, GPU, weights, vLLM"
  ./scripts/e2e.sh cni
  ./scripts/e2e.sh gpu-plugin
  ./scripts/e2e.sh storage
  # The cluster-default StorageClass. Applied here, before anything with an unqualified PVC
  # (Vault raft, kagent/agentregistry/management postgres) so those never sit Pending.
  ya 01-storageclass-gp3.yaml
  for s in iam gpu weights vllm; do ./scripts/e2e.sh "$s"; done
}

p_mesh() {
  banner "mesh: Istio ambient (base + istiod + cni + ztunnel)"
  # Must precede the CA phase: istio-csr.sh only rewires an existing mesh onto the Vault CA.
  ./scripts/ambient.sh up
}

p_ca() {
  banner "certificate authority: Vault PKI, then rewire the mesh CA to it via istio-csr"
  ./scripts/vault.sh up
  ./scripts/istio-csr.sh up
}

p_idp() { banner "identity provider: Keycloak (realm + CoreDNS rewrite)"; ./scripts/keycloak.sh up; }

p_gateway() {
  banner "gateway: agentgateway control plane, the Gateway + routes, then edge TLS"
  ./scripts/agentgateway.sh up
  # Creates the Gateway (yaml/30) and provisions the NLB; tls.sh needs that hostname to exist.
  ./scripts/agentgateway.sh route
  ./scripts/tls.sh up
}

p_gwpolicy() {
  banner "gateway policies: the model door (JWT, PII, rate limit) + the console routes"
  ya 32-jwt-policy.yaml       # Strict JWT: the model door lock (targets the Gateway; needs Keycloak JWKS)
  ya 34-uk-pii-guard.yaml     # UK PII guard on the model route
  ya 38-rate-limit.yaml       # per-identity rate limit on the model route
  # yaml/46 and 47 declare HTTPRoutes/policies in the agentregistry namespace, which the
  # platform phase does not create until later; create it now so the apply does not fail
  # NotFound (and so management.sh's re-apply of 46/47 succeeds too).
  ensure_ns agentregistry
  # UI routes + their Permissive-JWT exemptions, applied now so keycloak.sovereign.local is
  # reachable through the gateway before kagent / AR / management validate tokens against it.
  ya 46-ui-routes.yaml
  ya 47-ui-auth-exempt.yaml
  ./scripts/keycloak.sh check || echo "  (keycloak.sh check reported a mismatch; investigate before proceeding)"
}

p_enrol() {
  banner "enrol workloads in the mesh, then the mesh-dependent policies"
  ./scripts/ambient.sh enrol
  # A namespace's ambient label only captures a pod on its next start. vLLM and the gateway
  # were created in earlier phases, so restart them now, BEFORE applying the mesh seals: else
  # ztunnel never captures them (yaml/33/48/49 become no-ops) and the gateway has no SPIFFE
  # identity to reach the model. The gateway data-plane deploys carry the gateway-name label.
  kc -n models rollout restart deploy/vllm
  for d in $(kc -n agentgateway-system get deploy -l gateway.networking.k8s.io/gateway-name -o name 2>/dev/null); do
    kc -n agentgateway-system rollout restart "$d"
  done
  kc -n models rollout status deploy/vllm --timeout=600s
  for d in $(kc -n agentgateway-system get deploy -l gateway.networking.k8s.io/gateway-name -o name 2>/dev/null); do
    kc -n agentgateway-system rollout status "$d" --timeout=300s
  done
  ya 33-models-networkpolicy.yaml   # only the gateway's SPIFFE identity reaches the model
  ya 48-ambient-egress.yaml         # egress waypoint + default-deny (needs ambient + DNS capture)
  ya 49-agent-model-access.yaml     # in-cluster tokenless model route + ztunnel L4 seal
}

p_policy() {
  banner "admission policy: PSA + Kyverno + the hardening set"
  ./scripts/policy.sh up            # PSA labels, Kyverno, yaml/40
  ya 41-hardening.yaml              # restricted subset, read-only rootfs, generate rules
  ya 43-serviceaccount-hardening.yaml
}

p_obs() {
  banner "observability + alerting (Prometheus, Grafana, Alertmanager, Mailpit)"
  ./scripts/observability.sh up     # kube-prometheus-stack, Mailpit, yaml/80 + yaml/70
  ya 81-mesh-observability.yaml     # ztunnel + waypoint PodMonitors (needs Prometheus CRDs + ambient)
}

p_substrate() { banner "gVisor on the sandbox node group"; ./scripts/substrate.sh up; }

p_kagent() {
  banner "kagent runtime (OIDC to Keycloak) + the agent-admission policy"
  ./scripts/kagent.sh up
  ya 42-agent-admission.yaml        # matches kagent CRDs, so it must run after kagent is installed
}

p_platform() {
  banner "management plane (console + traces) and AgentRegistry"
  ./scripts/management.sh up        # collector + ClickHouse + solo-enterprise-ui; applies yaml/35,46,47
  ./scripts/agentregistry.sh up
}

p_register() {
  banner "publish the agent and the MCP server through AgentRegistry into kagent"
  ./scripts/ar-agent.sh all
  ./scripts/ar-mcp.sh all
}

p_seals() {
  banner "sovereignty seals + late posture (image mirror, DNS firewall, quotas, PDBs, egress)"
  ./scripts/registry-mirror.sh up   # ECR pull-through so images pull in-region
  ./scripts/dns.sh up               # Route 53 Resolver DNS Firewall (VPC-level egress guarantee)
  # Late-posture policy. Ensure the namespaces the quotas / default-deny target exist first
  # (the SSRF-demo namespace 'internal' is created here as base posture, empty until the demo).
  for ns in apps agents mcp-tools internal; do ensure_ns "$ns"; done
  ya 44-resource-quotas.yaml
  ya 99-default-deny-egress.yaml    # baseline default-deny egress
  # yaml/45-vault-secrets.yaml is intentionally NOT applied here: its SecretProviderClass
  # needs the Secrets Store CSI driver (which no phase installs) plus a Vault role
  # 'ar-secrets-reader' and a secret/data/agentregistry path (which vault.sh does not create),
  # so applying it on a fresh cluster fails NotFound and would abort the phase. Install the
  # CSI driver + Vault role first if you want to demo CSI-mounted secrets.
  # yaml/50-pdb.yaml is intentionally NOT applied: istiod, the gateway and Keycloak run a
  # single replica (Keycloak's dev-mode H2 cannot be scaled), so a minAvailable:1 PDB would
  # make those pods unevictable and wedge any node drain or roll. Apply it only after scaling
  # those components to >=2 for an HA deployment.
}

p_verify() {
  banner "verify: Mistral answers over TLS through the gateway, and the consoles have data"
  ./scripts/ask.sh "what city are you running in?"
  ./scripts/management.sh traces || true
  ./scripts/ar-agent.sh verify || true
}

PHASES=(cluster model mesh ca idp gateway gwpolicy enrol policy obs substrate kagent platform register seals verify)

case "${1:-all}" in
  phases) printf '%s\n' "${PHASES[@]}" ;;
  all)
    for p in "${PHASES[@]}"; do "p_${p}"; done
    banner "done"
    echo "Everything is up. Stop the GPU meter when you finish for the day:  ./scripts/gpu.sh down"
    echo "Consoles: age.sovereign.local (agentgateway), kagent.sovereign.local, registry.sovereign.local"
    echo "Fire the alert-email demo:  ./scripts/observability.sh alert   then   ./scripts/observability.sh mail"
    echo "Attack scenarios (run on top, not part of standing up):"
    echo "  ./scripts/artifactory.sh up && ./scripts/artifactory-ssrf.sh all   # SSRF + lockdown (yaml 90-93,99)"
    echo "  ./scripts/rate-limit.sh test                                       # 429 after 10/min"
    echo "  ./scripts/trivy.sh up                                              # CVE admission gate (yaml/82)"
    ;;
  *)
    fn="p_${1}"
    declare -F "$fn" >/dev/null || { echo "unknown phase '$1'. try: ${PHASES[*]}" >&2; exit 1; }
    "$fn"
    ;;
esac
