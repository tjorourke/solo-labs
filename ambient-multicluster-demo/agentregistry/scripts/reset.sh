#!/usr/bin/env bash
# reset.sh — return mesh1 to a clean demo-4 state. Removes only what the demo
# creates; leaves the platform (kagent, AgentRegistry, Keycloak) and the approved
# catalog up so the demo is re-runnable and Parts 1-3 are untouched.
#
#   - the agentdemo Agent + its kagent Deployment
#   - the deployed MCP tool servers (my-mcp, everything-server) on kind-kagent
#   - any AccessPolicy + the everything-server waypoint label
#   - the Petstore OpenAPI backend, route and ConfigMap
#   - the local ./agentdemo scaffold
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
unset ARCTL_API_TOKEN
arctl_login >/dev/null 2>&1 || warn "arctl not logged in — registry deletes may be skipped"

step "Reverting any AccessPolicy governance"
for p in $(kc -n kagent get accesspolicy -o name 2>/dev/null); do kc -n kagent delete "$p" >/dev/null 2>&1; done
kc -n kagent label mcpserver everything-server kagent.solo.io/waypoint- >/dev/null 2>&1 || true
ok "AccessPolicies cleared, waypoint label removed"

step "Removing the deployed agent + MCP tool servers"
arctl delete deployment agentdemo         >/dev/null 2>&1 || true
arctl delete deployment everything-server >/dev/null 2>&1 || true
arctl delete deployment my-mcp            >/dev/null 2>&1 || true
# also drop the agent record itself so a fresh run re-publishes cleanly
arctl delete agent agentdemo              >/dev/null 2>&1 || true
# belt-and-braces: remove any kagent CRs the registry left behind
kc -n kagent delete agent agentdemo                    >/dev/null 2>&1 || true
kc -n kagent delete mcpserver my-mcp everything-server >/dev/null 2>&1 || true
ok "agent + tool deployments removed"

step "Removing the Petstore OpenAPI backend"
kc -n agentgateway-system delete httproute petstore-mcp                          >/dev/null 2>&1 || true
kc -n agentgateway-system delete enterpriseagentgatewaybackend petstore-api      >/dev/null 2>&1 || true
kc -n agentgateway-system delete configmap petstore-openapi                      >/dev/null 2>&1 || true
ok "Petstore backend removed"

step "Removing the local scaffold"
rm -rf "$LAB_ROOT/agentdemo"
ok "clean — the platform + approved catalog remain up"

echo "" >&2
echo "  demo-4 reset. Approved catalog still present:" >&2
{ echo "  mcpservers:"; arctl get mcpservers 2>/dev/null; echo "  runtimes:"; arctl get runtimes 2>/dev/null; } | sed 's/^/  /' >&2
