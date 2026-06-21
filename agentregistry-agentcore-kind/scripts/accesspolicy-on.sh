#!/usr/bin/env bash
# accesspolicy-on.sh — restrict the agent's MCP tools with a kagent AccessPolicy,
# enforced at an agentgateway waypoint. Least-privilege as an ALLOWLIST: the
# agent may call ONLY `sum` on the everything-server; every other tool on that
# server (echo, printenv, ...) is denied. This mirrors the Enterprise UI flow
# (Access Policies -> Create: action ALLOW, target MCP Server, tools: sum).
#
# Requires the waypoint data plane (./scripts/05-waypoint.sh).
#
#   1. apply an AccessPolicy: ALLOW only `sum` for the agent on that MCPServer
#   2. label the everything-server MCPServer kagent.solo.io/waypoint=true
#      -> the kmcp translator provisions a waypoint Gateway + HTTPRoute +
#         AgentgatewayBackend in front of the MCP server (CLUSTER_ID/NETWORK
#         come from the GatewayClass params set at install); the waypoint then
#         enforces the allowlist.
#   3. restart the agent so it re-lists tools through the waypoint.
#
# Revert with accesspolicy-off.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

MCP="${MCP_SERVER:-everything-server}"
ALLOW_TOOL="${ALLOW_TOOL:-sum}"
POLICY="${POLICY_NAME:-allow-${ALLOW_TOOL}-only}"

kc get gatewayclass enterprise-agentgateway-waypoint >/dev/null 2>&1 \
  || die "waypoint GatewayClass missing — run ./scripts/05-waypoint.sh first"
kc -n kagent get mcpserver "$MCP" >/dev/null 2>&1 || die "MCPServer '$MCP' not found — deploy the agent first"
AGENT="$(resolve_kagent_agent agentdemo)"
[[ -n "$AGENT" ]] || die "no kagent agent matching 'agentdemo' — deploy it first"

step "1/3 — applying AccessPolicy: ALLOW only '$ALLOW_TOOL' for $AGENT on $MCP"
kc apply -f - <<EOF >/dev/null
apiVersion: policy.kagent-enterprise.solo.io/v1alpha1
kind: AccessPolicy
metadata:
  name: ${POLICY}
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
      - $ALLOW_TOOL
  action: ALLOW
EOF
for i in $(seq 1 20); do
  [[ "$(kc -n kagent get accesspolicy "$POLICY" -o jsonpath='{.status.state}' 2>/dev/null)" == "Applied" ]] && break
  sleep 2
done
ok "AccessPolicy ${POLICY}: $(kc -n kagent get accesspolicy "$POLICY" -o jsonpath='{.status.state}')"

step "2/3 — labelling MCPServer $MCP for the agentgateway waypoint (enforcement point)"
kc -n kagent label mcpserver "$MCP" kagent.solo.io/waypoint=true --overwrite >/dev/null
WP="mcpserver-${MCP}-waypoint"
log "waiting for waypoint Gateway to be Programmed"
for i in $(seq 1 30); do
  [[ "$(kc -n kagent get gateway "$WP" -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)" == "True" ]] && { ok "waypoint $WP programmed"; break; }
  sleep 3
done
kc -n kagent rollout status deploy/"$WP" --timeout=90s >/dev/null 2>&1 || true
log "EnterpriseAgentgatewayPolicy:"
kc -n kagent get enterpriseagentgatewaypolicies -o jsonpath='{range .items[*]}    {.metadata.name}: ACCEPTED={.status.ancestors[0].conditions[?(@.type=="Accepted")].status}{"\n"}{end}' >&2

step "3/3 — restarting the agent so it re-lists tools through the waypoint"
kc -n kagent rollout restart deploy/"$AGENT" >/dev/null 2>&1
kc -n kagent rollout status deploy/"$AGENT" --timeout=120s >/dev/null 2>&1 || true

cat >&2 <<EOF

✓ AccessPolicy enforcing. On the everything-server the agent may now call ONLY '$ALLOW_TOOL'.
  Show the policy as a declarative CR:
    kubectl --context $CTX -n kagent get accesspolicy ${POLICY} -o yaml
  Confirm the reduced tool list:
    ./scripts/ask.sh "List the exact names of every tool you can call."
  Revert:
    ./scripts/accesspolicy-off.sh
EOF
