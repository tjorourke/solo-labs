#!/usr/bin/env bash
# accesspolicy-off.sh — revert accesspolicy-on.sh. Deletes the AccessPolicy,
# removes the waypoint label from the MCPServer (tearing down the waypoint
# Gateway/HTTPRoute/AgentgatewayBackend), and restarts the agent so it sees the
# full tool list again (printenv back).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

MCP="${MCP_SERVER:-demo-everything-server-agentdemo}"
DENY_TOOL="${DENY_TOOL:-printenv}"
AGENT="$(resolve_kagent_agent agentdemo)"

step "Removing AccessPolicy + waypoint label"
kc -n kagent delete accesspolicy "deny-${DENY_TOOL}" >/dev/null 2>&1 && ok "deleted AccessPolicy deny-${DENY_TOOL}" || log "no AccessPolicy deny-${DENY_TOOL}"
kc -n kagent label mcpserver "$MCP" kagent.solo.io/waypoint- >/dev/null 2>&1 && ok "removed waypoint label from $MCP" || log "no waypoint label on $MCP"

if [[ -n "$AGENT" ]]; then
  step "Restarting the agent"
  kc -n kagent rollout restart deploy/"$AGENT" >/dev/null 2>&1
  kc -n kagent rollout status deploy/"$AGENT" --timeout=120s >/dev/null 2>&1 || true
fi
ok "reverted — the agent sees the full tool list again ($DENY_TOOL restored)"
