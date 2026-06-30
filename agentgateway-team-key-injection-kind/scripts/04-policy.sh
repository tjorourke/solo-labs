#!/usr/bin/env bash
# 04-policy.sh — Gateway, HTTPRoute (header-routed by team), and the JWT +
# claim-to-header EnterpriseAgentgatewayPolicy.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

step "Applying Gateway + HTTPRoute"
kc apply -f "$LAB_ROOT/yaml/agentgateway/gateway.yaml" >/dev/null
kc apply -f "$LAB_ROOT/yaml/agentgateway/httproute.yaml" >/dev/null
ok "gateway + route applied"

step "Rendering JWKS into the JWT policy (from the running mock-idp)"
JWKS="$(kc -n teamkey-demo exec deploy/mock-idp -- \
  python -c "import urllib.request;print(urllib.request.urlopen('http://localhost:8080/jwks.json').read().decode())" 2>/dev/null)"
[[ -n "$JWKS" ]] || die "could not fetch JWKS from mock-idp"
# Substitute the inline placeholder (use a non-/ sed delimiter; JWKS has no '|').
sed "s|__JWKS_INLINE__|${JWKS}|" "$LAB_ROOT/yaml/agentgateway/jwt-policy.yaml" | kc apply -f - >/dev/null
ok "JWT policy applied with inline JWKS"

step "Waiting for gateway LoadBalancer IP"
GW_IP=""
for i in $(seq 1 40); do
  GW_IP="$(kc -n agentgateway-system get svc teamkey-gateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -n "$GW_IP" ]] && break
  sleep 3
done
[[ -n "$GW_IP" ]] && ok "gateway LB IP: $GW_IP" || warn "gateway IP not yet assigned (Service DNS still resolves in-cluster)"

step "Policy ready"
echo "  Try it: ./scripts/capture-keys.sh" >&2
