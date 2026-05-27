#!/usr/bin/env bash
# 05-budgets.sh — Gateway, HTTPRoute, AgentgatewayBackend (LLM),
# JWT authentication policy, RateLimitConfig + EnterpriseAgentgatewayPolicy
# that enforces the per-team token budgets.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

step "Applying Gateway + HTTPRoute + AgentgatewayBackend"
kc apply -f "$LAB_ROOT/yaml/agentgateway/gateway.yaml" >/dev/null
kc apply -f "$LAB_ROOT/yaml/agentgateway/backend.yaml" >/dev/null
kc apply -f "$LAB_ROOT/yaml/agentgateway/httproute.yaml" >/dev/null
ok "Gateway + HTTPRoute + Backend applied"

step "Applying JWT authentication policy"
kc apply -f "$LAB_ROOT/yaml/agentgateway/jwt-policy.yaml" >/dev/null
ok "jwt-auth policy applied"

step "Applying RateLimitConfig (per-team token budgets)"
kc apply -f "$LAB_ROOT/yaml/agentgateway/ratelimit-config.yaml" >/dev/null
ok "RateLimitConfig applied (dba: 5k/hr · 50k/day, support: 20k/hr · 200k/day)"

step "Applying EnterpriseAgentgatewayPolicy (entRateLimit → RateLimitConfig)"
kc apply -f "$LAB_ROOT/yaml/agentgateway/ratelimit-policy.yaml" >/dev/null
ok "ratelimit policy applied"

# Wait for the gateway data plane Service to come up.
step "Waiting for gateway LoadBalancer IP"
GW_IP=""
for i in $(seq 1 40); do
  GW_IP="$(kc -n agentgateway-system get svc budgets-gateway \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -n "$GW_IP" ]] && break
  sleep 3
done
if [[ -n "$GW_IP" ]]; then
  ok "gateway LB IP: $GW_IP"
else
  warn "gateway IP not yet assigned (continuing — agent-internal Service DNS will still work)"
fi

step "Policies applied"
echo "  Next: ./scripts/06-observability.sh" >&2
