#!/usr/bin/env bash
# quick.sh — orchestrator for agentgateway-team-key-injection-kind.
#   ./quick.sh up | teardown | status

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

case "${1:-up}" in
  up)
    require_secrets
    bash "$SCRIPT_DIR/01-cluster.sh"
    bash "$SCRIPT_DIR/02-agentgateway.sh"
    bash "$SCRIPT_DIR/03-deploy.sh"
    bash "$SCRIPT_DIR/04-policy.sh"
    cat >&2 <<EOF

══════════════════════════════════════════════════════════════════
  agentgateway-team-key-injection-kind — UP
══════════════════════════════════════════════════════════════════
  Context:  $CTX
  Try it:   ./scripts/capture-keys.sh
  Teardown: ./scripts/quick.sh teardown
EOF
    ;;
  teardown)
    step "Deleting kind cluster '$CLUSTER_NAME'"
    if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
      kind delete cluster --name "$CLUSTER_NAME"; ok "deleted"
    else log "cluster '$CLUSTER_NAME' not present"; fi
    ;;
  status)
    step "Deployments"
    for ns in agentgateway-system teamkey-demo; do
      echo "  ─ $ns" >&2; kc -n "$ns" get deploy 2>/dev/null | sed 's/^/    /' >&2 || true
    done
    step "Backends + policy"
    kc -n agentgateway-system get agentgatewaybackend,enterpriseagentgatewaypolicy 2>/dev/null | sed 's/^/  /' >&2 || true
    ;;
  *) echo "Usage: $0 up|teardown|status" >&2; exit 2 ;;
esac
