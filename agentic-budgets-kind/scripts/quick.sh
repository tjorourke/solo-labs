#!/usr/bin/env bash
# quick.sh — one-shot orchestrator for the agentic-budgets-kind lab.
#
# Usage:
#   ./quick.sh up        — run 01..07 in order (idempotent on rerun)
#   ./quick.sh teardown  — delete the kind cluster
#   ./quick.sh status    — show key resources + URLs

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

cmd="${1:-up}"

case "$cmd" in
  up)
    load_secrets
    bash "$SCRIPT_DIR/01-cluster.sh"
    bash "$SCRIPT_DIR/02-agentgateway.sh"
    bash "$SCRIPT_DIR/03-kagent.sh"
    bash "$SCRIPT_DIR/04-llm-and-jwt.sh"
    bash "$SCRIPT_DIR/05-budgets.sh"
    bash "$SCRIPT_DIR/06-observability.sh"
    bash "$SCRIPT_DIR/07-agents.sh"
    bash "$SCRIPT_DIR/08-logging.sh"

    echo ""
    cat >&2 <<EOF
══════════════════════════════════════════════════════════════════
  agentic-budgets-kind — UP
══════════════════════════════════════════════════════════════════

  Context:  $CTX
  Next:     ./scripts/port-forward.sh
            (then open http://localhost:8080 + http://localhost:3000)

  Two agents are listed in the kagent UI:
    - dba-agent       (5,000 tokens / hour  ·  50,000 / day)
    - support-agent   (20,000 tokens / hour · 200,000 / day)

  In Grafana, open the "Per-Team LLM Token Budgets" dashboard.

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
    for ns in agentgateway-system kagent llm budgets monitoring; do
      echo "  ─ $ns" >&2
      kc -n "$ns" get deploy 2>/dev/null | tail -n +1 | sed 's/^/    /' >&2 || true
    done

    step "Gateway IP"
    GW_IP="$(kc -n agentgateway-system get svc budgets-gateway \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    [[ -n "$GW_IP" ]] && echo "  http://$GW_IP" >&2 || echo "  (gateway IP not yet assigned)" >&2

    step "Agents"
    kc -n kagent get agents 2>/dev/null | sed 's/^/  /' >&2 || true

    step "RateLimitConfig + EnterpriseAgentgatewayPolicy"
    kc -n agentgateway-system get ratelimitconfig 2>/dev/null | sed 's/^/  /' >&2 || true
    kc -n agentgateway-system get enterpriseagentgatewaypolicy 2>/dev/null | sed 's/^/  /' >&2 || true
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
