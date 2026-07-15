#!/usr/bin/env bash
# quick.sh — orchestrator for agentic-structured-output-kind (standalone cluster).
#   ./quick.sh up | teardown | status
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

case "${1:-up}" in
  up)
    require_secrets
    bash "$SCRIPT_DIR/01-cluster.sh"
    bash "$SCRIPT_DIR/02-kagent.sh"
    bash "$SCRIPT_DIR/03-images.sh"
    bash "$SCRIPT_DIR/04-agents.sh"
    cat >&2 <<EOF

══════════════════════════════════════════════════════════════════
  agentic-structured-output-kind — UP   (context: $CTX)
══════════════════════════════════════════════════════════════════

  One Diagnosis contract, enforced two ways, shared across the A2A hop:

    ./scripts/contract.sh declarative   # record_diagnosis MCP tool schema
    ./scripts/contract.sh byo           # ADK pydantic output_schema

  End to end — SRE investigates, delegates, folds in the verdict:

    ./scripts/ask.sh "the orders database won't start - investigate and fix"

  Dashboard:  ./scripts/port-forward.sh     # http://localhost:8080
  Reset DB:   kubectl --context $CTX -n orders rollout restart deploy/orders-db
  Teardown:   ./scripts/quick.sh teardown
EOF
    ;;
  teardown)
    step "Deleting kind cluster '$CLUSTER_NAME'"
    kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME" && { kind delete cluster --name "$CLUSTER_NAME"; ok "deleted"; } || log "not present"
    ;;
  status)
    step "kagent"; kc -n kagent get pods 2>/dev/null | sed 's/^/  /' >&2 || true
    step "Agents + MCP"; kc -n kagent get agent,remotemcpserver 2>/dev/null | sed 's/^/  /' >&2 || true
    step "Incident"; kc -n orders get pods 2>/dev/null | sed 's/^/  /' >&2 || true
    ;;
  *) echo "Usage: $0 up | teardown | status" >&2; exit 2;;
esac
