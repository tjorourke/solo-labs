#!/usr/bin/env bash
# quick.sh — orchestrator for agentic-tool-privilege-kind (standalone enterprise
# cluster). ./quick.sh up | teardown | status
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

case "${1:-up}" in
  up)
    require_secrets
    bash "$SCRIPT_DIR/01-cluster.sh"
    bash "$SCRIPT_DIR/02-keycloak.sh"
    bash "$SCRIPT_DIR/03-agentgateway.sh"
    bash "$SCRIPT_DIR/04-kagent.sh"
    bash "$SCRIPT_DIR/05-mcp-and-gateway.sh"
    bash "$SCRIPT_DIR/06-agents.sh"
    cat >&2 <<EOF

══════════════════════════════════════════════════════════════════
  agentic-tool-privilege-kind — UP   (context: $CTX)
══════════════════════════════════════════════════════════════════

  Two agents, two identities, one MCP server. The gateway decides who
  gets which tool:

    ./scripts/tools.sh     # tools/list as db-reader vs db-operator (different sets)
    ./scripts/prove.sh     # reader denied db_reset_credentials; operator fixes the DB
    ./scripts/ask.sh dba-diagnoser  "the orders database is down - diagnose it"
    ./scripts/ask.sh sre-remediator "the orders database is down - fix it"

  Dashboard:      ./scripts/port-forward.sh     # http://localhost:8080
  Refresh tokens: ./scripts/refresh-tokens.sh   # if the 12h agent tokens expire
  Teardown:       ./scripts/quick.sh teardown
EOF
    ;;
  teardown)
    step "Deleting kind cluster '$CLUSTER_NAME'"
    kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME" && { kind delete cluster --name "$CLUSTER_NAME"; ok "deleted"; } || log "not present"
    ;;
  status)
    step "Keycloak";  kc -n "$KEYCLOAK_NS" get pods 2>/dev/null | sed 's/^/  /' >&2 || true
    step "agentgateway"; kc -n agentgateway-system get pods,gateway 2>/dev/null | sed 's/^/  /' >&2 || true
    step "kagent";    kc -n kagent get pods 2>/dev/null | sed 's/^/  /' >&2 || true
    step "mock-db";   kc -n mock-db get pods 2>/dev/null | sed 's/^/  /' >&2 || true
    step "Agents + MCP + policies"; kc -n kagent get agent,remotemcpserver 2>/dev/null | sed 's/^/  /' >&2 || true
    kc -n mock-db get enterpriseagentgatewaypolicy 2>/dev/null | sed 's/^/  /' >&2 || true
    ;;
  *) echo "Usage: $0 up | teardown | status" >&2; exit 2;;
esac
