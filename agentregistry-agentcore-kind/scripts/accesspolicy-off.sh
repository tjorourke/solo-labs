#!/usr/bin/env bash
# accesspolicy-off.sh — revert accesspolicy-on.sh. Deletes the AccessPolicy,
# removes the waypoint label from the MCPServer (tearing down the waypoint
# Gateway/HTTPRoute/AgentgatewayBackend), and restarts the agent so it sees the
# full tool list again. Also clears a policy created by name in the UI.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

MCP="${MCP_SERVER:-demo-everything-server-agentdemo}"
ALLOW_TOOL="${ALLOW_TOOL:-sum}"
POLICY="${POLICY_NAME:-allow-${ALLOW_TOOL}-only}"
AGENT="$(resolve_kagent_agent agentdemo)"

step "Removing AccessPolicy + waypoint label"
# delete the scripted policy by name, plus any policy targeting this MCP server
# (e.g. one created in the Enterprise UI under a different name)
kc -n kagent delete accesspolicy "$POLICY" >/dev/null 2>&1 && ok "deleted AccessPolicy $POLICY" || log "no AccessPolicy $POLICY"
for p in $(kc -n kagent get accesspolicy -o jsonpath="{range .items[?(@.spec.targetRef.name=='$MCP')]}{.metadata.name}{'\n'}{end}" 2>/dev/null); do
  kc -n kagent delete accesspolicy "$p" >/dev/null 2>&1 && ok "deleted AccessPolicy $p (targets $MCP)" || true
done
kc -n kagent label mcpserver "$MCP" kagent.solo.io/waypoint- >/dev/null 2>&1 && ok "removed waypoint label from $MCP" || log "no waypoint label on $MCP"

if [[ -n "$AGENT" ]]; then
  step "Restarting the agent"
  kc -n kagent rollout restart deploy/"$AGENT" >/dev/null 2>&1
  kc -n kagent rollout status deploy/"$AGENT" --timeout=120s >/dev/null 2>&1 || true
fi
ok "reverted — the agent sees the full everything-server tool list again"
