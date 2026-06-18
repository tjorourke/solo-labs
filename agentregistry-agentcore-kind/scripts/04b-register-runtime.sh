#!/usr/bin/env bash
# 04b-register-runtime.sh — register the Kubernetes Runtime that points the local
# arctl daemon at the kind cluster. This is platform plumbing (done by setup.sh),
# so the notebook's deploy step is a clean one-liner against an existing runtime.
#
# The daemon runs in Docker, so we join it to the kind network and feed it the
# cluster's *internal* kubeconfig (API server = the control-plane container
# hostname, reachable over that network, TLS SAN matches).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
arctl_token

step "Registering the Kubernetes Runtime 'kind-kagent'"
DAEMON_CTR="$(docker ps --filter publish=12121 --format '{{.Names}}' | head -1)"
[[ -n "$DAEMON_CTR" ]] || die "arctl daemon not running (publishing :12121) — run 04-daemon.sh first"
docker network connect kind "$DAEMON_CTR" >/dev/null 2>&1 || true

RT_YAML="$(mktemp)"
{
  cat <<EOF
apiVersion: ar.dev/v1alpha1
kind: Runtime
metadata:
  name: kind-kagent
spec:
  type: Kubernetes
  config:
    namespace: kagent
    kubeconfig: |
EOF
  kind get kubeconfig --internal --name "$CLUSTER_NAME" | sed 's/^/      /'
} > "$RT_YAML"
arctl apply -f "$RT_YAML"; rm -f "$RT_YAML"
arctl get runtimes 2>/dev/null | sed 's/^/  /' >&2 || true
ok "runtime kind-kagent registered"
