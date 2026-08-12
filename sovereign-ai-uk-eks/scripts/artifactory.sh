#!/usr/bin/env bash
# JFrog Artifactory OSS, as an SSRF target and then as a contained one.
#
# Artifactory is a repository manager: by design it makes server-side outbound
# requests, its remote repositories proxy upstream registries. That same feature is a
# textbook SSRF primitive: point a remote repository (or its "test URL" admin call) at an
# internal address and Artifactory will connect to it for you. This script stands it up,
# then the ssrf/lockdown steps recreate the SSRF and contain it with the same layers the
# rest of the lab uses.
#
#   ./scripts/artifactory.sh up        install Artifactory OSS (platform node group)
#   ./scripts/artifactory.sh url        the in-cluster base URL
#   ./scripts/artifactory.sh creds      the bootstrap admin credentials
#   ./scripts/artifactory.sh status     what is running
#   ./scripts/artifactory.sh down       remove it
#
# The SSRF recreate + block live in artifactory-ssrf.sh so this file stays the install.
set -euo pipefail

export AWS_PROFILE="${SOVEREIGN_AWS_PROFILE:?set SOVEREIGN_AWS_PROFILE to the sandbox SSO profile}"
REGION=eu-west-2
CLUSTER=uk-sovereign-ai
NS=artifactory
# Pinned to the last chart that supports monolithic (single-container) Artifactory. From
# chart 107.161 the split-services layout is mandatory and deadlocks on boot on a single
# node; 107.146 (app 7.146) runs everything in one container and boots reliably.
CHART_VERSION="${ARTIFACTORY_CHART_VERSION:-107.146.35}"   # appVersion 7.146.35

ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
[ -n "$ACCOUNT" ] && [ "$ACCOUNT" != "None" ] || { echo "error: no AWS identity; check SOVEREIGN_AWS_PROFILE" >&2; exit 1; }
CTX="arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${CLUSTER}"
kc() { command kubectl --context "$CTX" "$@"; }
helm_() { command helm --kube-context "$CTX" "$@"; }

case "${1:-status}" in
  up)
    helm_ repo add jfrog https://charts.jfrog.io >/dev/null 2>&1 || true
    helm_ repo update jfrog >/dev/null 2>&1 || true

    # baseline PSA: Artifactory's init containers chown volumes and it runs a bundled
    # Postgres, which restricted would fight. baseline is enough; the containment here is
    # the network and the gateway, not the pod profile.
    kc create namespace "$NS" --dry-run=client -o yaml | kc apply -f - >/dev/null
    kc label ns "$NS" pod-security.kubernetes.io/enforce=baseline --overwrite >/dev/null

    # The chart mandates a master key and a join key. Generate them once and keep them in a
    # secret so re-runs reuse the same keys (regenerating would break an upgrade). Generated
    # at runtime, never committed.
    if ! kc -n "$NS" get secret artifactory-mandatory-keys >/dev/null 2>&1; then
      kc -n "$NS" create secret generic artifactory-mandatory-keys \
        --from-literal=master-key="$(openssl rand -hex 32)" \
        --from-literal=join-key="$(openssl rand -hex 32)" >/dev/null
      echo "    generated master/join keys (secret artifactory-mandatory-keys)"
    fi

    echo "==> Artifactory OSS $CHART_VERSION (this is a heavy unified stack; give it 5-10 min)"
    helm_ upgrade --install artifactory jfrog/artifactory \
      --kube-context "$CTX" -n "$NS" --version "$CHART_VERSION" --wait --timeout 15m \
      --set global.masterKeySecretName=artifactory-mandatory-keys \
      --set global.joinKeySecretName=artifactory-mandatory-keys \
      -f - >/dev/null <<'VALUES'
# Run all services in one container, the classic monolithic mode. The split-services
# layout (separate frontend/jfbus deployments) deadlocks on boot: those pods wait for the
# router's readiness while the router waits for the services they provide. Monolithic is
# the reliable OSS shape and boots far faster.
splitServicesToContainers: false
# OSS edition: the artifactory-oss image needs no license. The chart prepends the
# registry (releases-docker.jfrog.io), so repository is the path only.
artifactory:
  image:
    repository: jfrog/artifactory-oss
  # keep the whole thing on the platform node group, off the GPU and sandbox pools.
  nodeSelector:
    eks.amazonaws.com/nodegroup: platform
  persistence:
    size: 20Gi
  # hold the JVM footprint down for a demo; this is not a sizing exercise.
  extraEnvironmentVariables:
    - name: EXTRA_JAVA_OPTIONS
      value: "-Xms1g -Xmx3g"
  resources:
    requests: { cpu: "500m", memory: "3Gi" }
    limits:   { memory: "6Gi" }
# no nginx tier: reach it by ClusterIP, and later front it through agentgateway for its
# own DNS name like every other UI in the lab.
nginx:
  enabled: false
# bundled Postgres, pinned to the platform pool and kept small.
postgresql:
  enabled: true
  primary:
    nodeSelector:
      eks.amazonaws.com/nodegroup: platform
    resources:
      requests: { cpu: "150m", memory: "512Mi" }
      limits:   { memory: "1Gi" }
    persistence:
      size: 10Gi
VALUES
    kc -n "$NS" rollout status statefulset/artifactory --timeout=120s 2>/dev/null || true
    echo "    installed. base URL: $("$0" url)"
    echo "    admin bootstrap:     $("$0" creds)"
    ;;

  url)
    echo "http://artifactory.${NS}.svc.cluster.local:8082"
    ;;

  creds)
    # the chart seeds admin/password by default on OSS unless overridden.
    echo "admin / password  (change on first login; this is a demo)"
    ;;

  status)
    kc -n "$NS" get pods -o wide --no-headers 2>/dev/null || echo "  not installed"
    ;;

  down)
    helm_ uninstall artifactory -n "$NS" >/dev/null 2>&1 || true
    kc delete ns "$NS" --wait=false >/dev/null 2>&1 || true
    echo "removed"
    ;;

  *) echo "usage: $0 {up|url|creds|status|down}"; exit 1 ;;
esac
