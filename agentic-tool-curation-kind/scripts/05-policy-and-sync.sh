#!/usr/bin/env bash
# 05-policy-and-sync.sh — apply the gateway policies + start policy-sync.
#
# Order matters here:
#   1. Apply the gateway, route, JWT, and ext-auth policies.
#   2. Apply the INITIAL tool-allowlist policy as a bootstrap snapshot.
#   3. Bring up the policy-sync controller, which will take over the
#      tool-allowlist policy (FieldManager=policy-sync, force-applies).
#
# Once policy-sync is running, edits to the curation-manifest ConfigMap
# propagate to the allow-list within a few seconds.

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

step "Applying initial tool allow-list policy (bootstrap)"
kc apply -f "$LAB_ROOT/yaml/agentgateway/initial-allowlist.yaml" >/dev/null
ok "initial allow-list applied"

# Deploy policy-sync controller
step "Deploying policy-sync controller"
kc apply -f "$LAB_ROOT/yaml/policy-sync/serviceaccount.yaml" >/dev/null
kc apply -f "$LAB_ROOT/yaml/policy-sync/rbac.yaml" >/dev/null
kc apply -f "$LAB_ROOT/yaml/policy-sync/deployment.yaml" >/dev/null
wait_deploy tool-curation policy-sync 120s
ok "policy-sync ready"

# Wait for the gateway data plane Service to come up.
step "Waiting for gateway LoadBalancer IP"
GW_IP=""
for i in $(seq 1 40); do
  GW_IP="$(kc -n agentgateway-system get svc curation-gateway \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -n "$GW_IP" ]] && break
  sleep 3
done
if [[ -n "$GW_IP" ]]; then
  ok "gateway LB IP: $GW_IP"
else
  warn "gateway IP not yet assigned (continuing — in-cluster Service DNS still works)"
fi

step "Policies + controller applied"
echo "  Next: ./scripts/port-forward.sh, then open http://localhost:8090" >&2
