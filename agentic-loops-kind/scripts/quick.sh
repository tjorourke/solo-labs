#!/usr/bin/env bash
# quick.sh — one-shot orchestrator for the agentic-loops-kind lab.
#
# Usage:
#   ./quick.sh up        — run 01..04 in order (idempotent on rerun)
#   ./quick.sh teardown  — delete the kind cluster
#   ./quick.sh status    — show key resources + URLs

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

cmd="${1:-up}"

case "$cmd" in
  up)
    require_secrets
    bash "$SCRIPT_DIR/01-cluster.sh"
    bash "$SCRIPT_DIR/02-agentgateway.sh"
    bash "$SCRIPT_DIR/03-mcp-and-jwt.sh"
    bash "$SCRIPT_DIR/04-policy.sh"

    echo ""
    cat >&2 <<EOF
══════════════════════════════════════════════════════════════════
  agentic-loops-kind — UP
══════════════════════════════════════════════════════════════════

  Context:  $CTX
  Next:     ./scripts/port-forward.sh
            then open http://localhost:8090 — the Runaway Inspector UI.

            Run the four scenarios in order:
              S1 · well-behaved task          → 5 calls, all allowed
              S2 · max tool calls cap         → cut off at ~call 11
              S3 · max chain depth cap        → cut off at ~call 5
              S4 · repetition                  → 2nd call denied

  Teardown:
    ./scripts/quick.sh teardown
EOF
    ;;

  teardown)
    step "Deleting kind cluster '$CLUSTER_NAME'"
    if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
      kind delete cluster --name "$CLUSTER_NAME"
      ok "cluster '$CLUSTER_NAME' deleted"
    else
      log "cluster '$CLUSTER_NAME' not present — nothing to do"
    fi
    ;;

  status)
    step "Cluster"
    kc cluster-info 2>/dev/null | head -2 || die "cluster not reachable (is it up?)"

    step "Key deployments"
    for ns in agentgateway-system runaway-containment; do
      echo "  ─ $ns" >&2
      kc -n "$ns" get deploy 2>/dev/null | tail -n +1 | sed 's/^/    /' >&2 || true
    done

    step "Gateway IP"
    GW_IP="$(kc -n agentgateway-system get svc loops-gateway \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    [[ -n "$GW_IP" ]] && echo "  http://$GW_IP" >&2 || echo "  (gateway IP not yet assigned)" >&2

    step "Inspector UI"
    kc -n runaway-containment get deploy runaway-inspector-ui 2>/dev/null | sed 's/^/  /' >&2 || true

    step "Current budgets (from ConfigMap)"
    kc -n runaway-containment get configmap budgets \
      -o jsonpath='{.data.budgets\.yaml}' 2>/dev/null | sed 's/^/  /' >&2 || true
    ;;

  *)
    cat >&2 <<EOF
Usage:
  $0 up        — bring up the full lab
  $0 teardown  — delete the kind cluster
  $0 status    — show key resources

EOF
    exit 2
    ;;
esac
