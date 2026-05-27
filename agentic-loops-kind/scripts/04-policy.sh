#!/usr/bin/env bash
# 04-policy.sh — apply the gateway + route + JWT + ext-auth policies.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

step "Applying Gateway + HTTPRoute + AgentgatewayBackend"
kc apply -f "$LAB_ROOT/yaml/agentgateway/gateway.yaml" >/dev/null
kc apply -f "$LAB_ROOT/yaml/agentgateway/httproute.yaml" >/dev/null
ok "gateway + route applied"

step "Applying JWT authentication policy"
kc apply -f "$LAB_ROOT/yaml/agentgateway/jwt-policy.yaml" >/dev/null
ok "jwt-auth policy applied"

step "Applying ext-auth policy"
kc apply -f "$LAB_ROOT/yaml/agentgateway/extauth-policy.yaml" >/dev/null
ok "ext-auth policy applied"

# Wait for the gateway data plane Service to come up.
step "Waiting for gateway LoadBalancer IP"
GW_IP=""
for i in $(seq 1 40); do
  GW_IP="$(kc -n agentgateway-system get svc loops-gateway \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -n "$GW_IP" ]] && break
  sleep 3
done
if [[ -n "$GW_IP" ]]; then
  ok "gateway LB IP: $GW_IP"
else
  warn "gateway IP not yet assigned (in-cluster Service DNS still works)"
fi

step "Policies applied"
echo "  Next: ./scripts/port-forward.sh, then open http://localhost:8090" >&2
