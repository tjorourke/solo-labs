#!/usr/bin/env bash
# accesspolicy-on.sh — restrict the agent's MCP tools with a kagent AccessPolicy,
# enforced at an agentgateway waypoint. Demonstrates least-privilege: the agent
# keeps sum/echo/... but is DENIED the printenv tool.
#
# Requires the waypoint data plane (./scripts/05-waypoint.sh).
#
#   1. label the everything-server MCPServer kagent.solo.io/waypoint=true
#      -> the kmcp translator provisions a waypoint Gateway + HTTPRoute +
#         AgentgatewayBackend in front of the MCP server (CLUSTER_ID/NETWORK
#         come from the GatewayClass params set at install).
#   2. apply an AccessPolicy: DENY tool `printenv` for the agent on that MCPServer
#      -> the controller compiles it into an EnterpriseAgentgatewayPolicy on the
#         backend; the waypoint hides/denies printenv.
#   3. restart the agent so it re-lists tools through the waypoint.
#
# Revert with accesspolicy-off.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

MCP="${MCP_SERVER:-demo-everything-server-agentdemo}"
DENY_TOOL="${DENY_TOOL:-printenv}"

kc get gatewayclass enterprise-agentgateway-waypoint >/dev/null 2>&1 \
  || die "waypoint GatewayClass missing — run ./scripts/05-waypoint.sh first"
kc -n kagent get mcpserver "$MCP" >/dev/null 2>&1 || die "MCPServer '$MCP' not found — deploy the agent first"
AGENT="$(resolve_kagent_agent agentdemo)"
[[ -n "$AGENT" ]] || die "no kagent agent matching 'agentdemo' — deploy it first"

step "1/3 — labelling MCPServer $MCP for the agentgateway waypoint"
kc -n kagent label mcpserver "$MCP" kagent.solo.io/waypoint=true --overwrite >/dev/null
WP="mcpserver-${MCP}-waypoint"
log "waiting for waypoint Gateway to be Programmed"
for i in $(seq 1 30); do
  [[ "$(kc -n kagent get gateway "$WP" -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)" == "True" ]] && { ok "waypoint $WP programmed"; break; }
  sleep 3
done
kc -n kagent rollout status deploy/"$WP" --timeout=90s >/dev/null 2>&1 || true

step "2/3 — applying AccessPolicy: DENY tool '$DENY_TOOL' for $AGENT on $MCP"
kc apply -f - <<EOF >/dev/null
apiVersion: policy.kagent-enterprise.solo.io/v1alpha1
kind: AccessPolicy
metadata:
  name: deny-${DENY_TOOL}
  namespace: kagent
spec:
  from:
    subjects:
      - kind: Agent
        name: $AGENT
        namespace: kagent
  targetRef:
    kind: MCPServer
    name: $MCP
    tools:
      - $DENY_TOOL
  action: DENY
EOF
for i in $(seq 1 20); do
  [[ "$(kc -n kagent get accesspolicy "deny-${DENY_TOOL}" -o jsonpath='{.status.state}' 2>/dev/null)" == "Applied" ]] && break
  sleep 2
done
ok "AccessPolicy deny-${DENY_TOOL}: $(kc -n kagent get accesspolicy "deny-${DENY_TOOL}" -o jsonpath='{.status.state}')"
log "EnterpriseAgentgatewayPolicy:"
kc -n kagent get enterpriseagentgatewaypolicies -o jsonpath='{range .items[*]}    {.metadata.name}: ACCEPTED={.status.ancestors[0].conditions[?(@.type=="Accepted")].status}{"\n"}{end}' >&2

step "3/3 — restarting the agent so it re-lists tools through the waypoint"
kc -n kagent rollout restart deploy/"$AGENT" >/dev/null 2>&1
kc -n kagent rollout status deploy/"$AGENT" --timeout=120s >/dev/null 2>&1 || true

cat >&2 <<EOF

✓ AccessPolicy enforcing. The agent can no longer call '$DENY_TOOL'.
  Show the policy as a declarative CR:
    kubectl --context $CTX -n kagent get accesspolicy deny-${DENY_TOOL} -o yaml
  Confirm the reduced tool list:
    ./scripts/ask.sh "List the exact names of every tool you can call."
  Revert:
    ./scripts/accesspolicy-off.sh
EOF
