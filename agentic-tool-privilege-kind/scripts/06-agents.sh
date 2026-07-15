#!/usr/bin/env bash
# 06-agents.sh — the two RemoteMCPServers (each injecting one identity token) and
# the two agents that use them.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

step "Applying RemoteMCPServers (reader + operator identities)"
kc apply -f "$LAB_ROOT/yaml/agents/remotemcpservers.yaml" >/dev/null
ok "db-mcp-reader + db-mcp-operator applied"

step "Applying agents"
kc apply -f "$LAB_ROOT/yaml/agents/dba-diagnoser.yaml" >/dev/null
kc apply -f "$LAB_ROOT/yaml/agents/sre-remediator.yaml" >/dev/null
ok "dba-diagnoser + sre-remediator applied"

step "Waiting for the agents to be Ready"
wait_agent dba-diagnoser 360  && ok "dba-diagnoser Ready"  || warn "dba-diagnoser not Ready"
wait_agent sre-remediator 360 && ok "sre-remediator Ready" || warn "sre-remediator not Ready"
kc -n kagent get agent dba-diagnoser sre-remediator >&2 || true

step "Agents ready"
cat >&2 <<EOF
  See the two identities get different tool sets from the SAME MCP server:
    ./scripts/tools.sh                  # tools/list as db-reader vs db-operator
  Prove one agent can do what the other can't:
    ./scripts/prove.sh                  # reader denied db_reset_credentials; operator fixes the DB
  End to end via the agents:
    ./scripts/ask.sh dba-diagnoser  "the orders database is down - diagnose it"
    ./scripts/ask.sh sre-remediator "the orders database is down - fix it"
EOF
