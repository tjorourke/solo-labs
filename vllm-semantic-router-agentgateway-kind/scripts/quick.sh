#!/usr/bin/env bash
# quick.sh — one-shot orchestrator for vllm-semantic-router-agentgateway-kind.
#
# Usage:
#   ./quick.sh up        — run 01..05 in order (idempotent on rerun)
#   ./quick.sh teardown  — delete the kind cluster
#   ./quick.sh status    — show key resources
#   ./quick.sh test      — run the routing test (needs the lab up)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

cmd="${1:-up}"

case "$cmd" in
  up)
    require_secrets
    bash "$SCRIPT_DIR/01-cluster.sh"
    bash "$SCRIPT_DIR/02-agentgateway.sh"
    bash "$SCRIPT_DIR/03-vllm-backend.sh"
    bash "$SCRIPT_DIR/04-semantic-router.sh"
    bash "$SCRIPT_DIR/05-routing.sh"

    echo ""
    cat >&2 <<EOF
══════════════════════════════════════════════════════════════════
  vllm-semantic-router-agentgateway-kind — UP
══════════════════════════════════════════════════════════════════

  Context:  $CTX
  Test:     ./scripts/test.sh
  Manual:   ./scripts/port-forward.sh
            curl -X POST http://localhost:18080/v1/chat/completions \\
              -H 'Content-Type: application/json' \\
              -d '{"model":"auto","messages":[{"role":"user",
                   "content":"What is the derivative of x^3?"}]}'

  Teardown: ./scripts/quick.sh teardown
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
    echo "  ─ default" >&2
    kc -n default get deploy 2>/dev/null | sed 's/^/    /' >&2 || true
    echo "  ─ agentgateway-system" >&2
    kc -n agentgateway-system get deploy 2>/dev/null | sed 's/^/    /' >&2 || true

    step "Gateway / route / backend / policy"
    kc -n agentgateway-system get gateway,httproute,agentgatewaybackend,enterpriseagentgatewaypolicy \
      2>/dev/null | sed 's/^/  /' >&2 || true
    ;;

  test)
    bash "$SCRIPT_DIR/test.sh"
    ;;

  *)
    cat >&2 <<EOF
Usage:
  $0 up        — bring up the full lab
  $0 teardown  — delete the kind cluster
  $0 status    — show key resources
  $0 test      — run the routing test

EOF
    exit 2
    ;;
esac
