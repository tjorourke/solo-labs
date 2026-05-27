#!/usr/bin/env bash
# 04-mcp-and-hitl.sh — build + kind-load + deploy the three custom services.
#
#   ops-tools       — Python MCP server (mock DB)
#   hitl-extauth    — Go gRPC ext-auth + admin HTTP
#   hitl-ui         — Go HTMX approval queue
#
# Then applies the gateway / HTTPRoute / EAGW policy / RemoteMCPServer manifests.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

# ── 1. Build + load images ────────────────────────────────────────────────────
step "Building and loading custom images into kind"
build_and_load "$LAB_ROOT/src/ops-tools"     "$OPS_TOOLS_IMAGE"
build_and_load "$LAB_ROOT/src/hitl-extauth"  "$HITL_EXTAUTH_IMAGE"
build_and_load "$LAB_ROOT/src/hitl-ui"       "$HITL_UI_IMAGE"

# ── 2. Namespaces ─────────────────────────────────────────────────────────────
step "Creating namespaces"
kc apply -f "$LAB_ROOT/yaml/namespaces/00-namespaces.yaml" >/dev/null
ok "ops-tools, hitl namespaces ready"

# ── 3. Deploy ops-tools MCP server ───────────────────────────────────────────
step "Deploying ops-tools MCP server"
kc apply -f "$LAB_ROOT/yaml/ops-tools/deployment.yaml" >/dev/null
wait_deploy ops-tools ops-tools 120s
ok "ops-tools ready"

# ── 4. Deploy hitl-extauth + hitl-ui ──────────────────────────────────────────
step "Deploying hitl-extauth"
kc apply -f "$LAB_ROOT/yaml/hitl/extauth.yaml" >/dev/null
wait_deploy hitl hitl-extauth 120s
ok "hitl-extauth ready"

step "Deploying hitl-ui"
kc apply -f "$LAB_ROOT/yaml/hitl/ui.yaml" >/dev/null
wait_deploy hitl hitl-ui 120s
ok "hitl-ui ready"

# ── 5. Apply the gateway + routes + extauth policy ───────────────────────────
step "Applying Gateway + HTTPRoutes"
kc apply -f "$LAB_ROOT/yaml/agentgateway/gateway.yaml" >/dev/null
kc apply -f "$LAB_ROOT/yaml/agentgateway/httproutes.yaml" >/dev/null
ok "Gateway + HTTPRoutes applied"

step "Applying AgentgatewayPolicy (extAuth → hitl-extauth)"
kc apply -f "$LAB_ROOT/yaml/agentgateway/extauth-policy.yaml" >/dev/null
ok "extauth policy applied"

# Wait for the gateway data plane Service to come up.
step "Waiting for gateway LoadBalancer IP"
GW_IP=""
for i in $(seq 1 40); do
  GW_IP="$(kc -n agentgateway-system get svc hitl-gateway \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -n "$GW_IP" ]] && break
  sleep 3
done
if [[ -n "$GW_IP" ]]; then
  ok "gateway LB IP: $GW_IP"
else
  warn "gateway IP not yet assigned (continuing — agent-internal Service DNS will still work)"
fi

# ── 6. Apply the two RemoteMCPServer resources ────────────────────────────────
step "Registering RemoteMCPServer resources in kagent ns"
kc apply -f "$LAB_ROOT/yaml/mcp/remote-mcp-servers.yaml" >/dev/null
ok "RemoteMCPServer resources applied"

step "All components deployed"
echo "  Next: ./scripts/05-agents.sh" >&2
