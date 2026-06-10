#!/usr/bin/env bash
# quick.sh — orchestrator for agentgw-code-mode-kind.
#   ./quick.sh up | teardown | status

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

case "${1:-up}" in
  up)
    require_secrets
    bash "$SCRIPT_DIR/01-cluster.sh"
    bash "$SCRIPT_DIR/02-agentgateway.sh"
    bash "$SCRIPT_DIR/03-backend-route.sh"
    echo ""
    cat >&2 <<EOF
══════════════════════════════════════════════════════════════════
  agentgw-code-mode-kind — UP
══════════════════════════════════════════════════════════════════

  Context: $CTX

  The petstore OpenAPI is exposed in CODE MODE: one run_code tool +
  a generated TypeScript API, JS executed in the gateway sandbox.

    ./scripts/port-forward.sh                 # gateway → http://localhost:18770
    ./scripts/show-tools.sh                   # run_code + the generated TypeScript
    ./scripts/run-code.sh                     # add / find / delete a pet via JS
    ./scripts/ask-llm.sh "add a pet ..."      # Claude writes the JS

  Teardown:  ./scripts/quick.sh teardown
EOF
    ;;
  teardown)
    step "Deleting kind cluster '$CLUSTER_NAME'"
    kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME" \
      && { kind delete cluster --name "$CLUSTER_NAME"; ok "deleted"; } \
      || log "cluster '$CLUSTER_NAME' not present"
    ;;
  status)
    step "agentgateway"; kc -n "$AGW_NS" get pods 2>/dev/null | sed 's/^/  /' >&2 || true
    step "Backends + route"; kc -n "$AGW_NS" get enterpriseagentgatewaybackend,gateway,httproute 2>/dev/null | sed 's/^/  /' >&2 || true
    ;;
  *) echo "Usage: $0 up | teardown | status" >&2; exit 2 ;;
esac
