#!/usr/bin/env bash
# 05-routing.sh — wire the data path:
#   Gateway (enterprise-agentgateway) → HTTPRoute → AgentgatewayBackend (vLLM)
#   + EnterpriseAgentgatewayPolicy attaching the Semantic Router as ExtProc.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

step "Applying Gateway"
kc apply -f "$LAB_ROOT/yaml/agentgateway/gateway.yaml" >/dev/null
ok "vllm-gateway applied"

log "waiting for the gateway proxy deployment to become Available..."
wait_deploy agentgateway-system vllm-gateway 300s
ok "gateway proxy ready"

step "Applying AgentgatewayBackend + HTTPRoute"
kc apply -f "$LAB_ROOT/yaml/agentgateway/backend.yaml" >/dev/null
kc apply -f "$LAB_ROOT/yaml/agentgateway/httproute.yaml" >/dev/null
ok "backend + route applied"

step "Applying AgentgatewayPolicy (Semantic Router ExtProc)"
kc apply -f "$LAB_ROOT/yaml/agentgateway/extproc-policy.yaml" >/dev/null
ok "extProc policy applied"

step "Routing ready"
echo "  Port-forward:  ./scripts/port-forward.sh" >&2
echo "  Test routing:  ./scripts/test.sh" >&2
