#!/usr/bin/env bash
# 23-ingress.sh — HTTPRoutes for the platform consoles on the single gateway:
#   keycloak.localtest.me      -> keycloak.keycloak:80                  (OIDC issuer)
#   agentregistry.localtest.me -> agentregistry-enterprise-server:12121 (AR UI/API)
# The agent routes (/portfolio-*) come later, in 40-gateway-config.sh, once the
# AgentCore runtimes exist.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

step "Console HTTPRoutes"
kc create namespace "$AR_NS" --dry-run=client -o yaml | kc apply -f - >/dev/null
kc apply -f - >/dev/null <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: keycloak, namespace: ${KEYCLOAK_NS} }
spec:
  parentRefs: [{ name: ${GW_NAME}, namespace: ${GW_NS} }]
  hostnames: ["${KEYCLOAK_HOST}"]
  rules:
    - matches: [{ path: { type: PathPrefix, value: / } }]
      backendRefs: [{ name: keycloak, port: 80 }]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: agentregistry, namespace: ${AR_NS} }
spec:
  parentRefs: [{ name: ${GW_NAME}, namespace: ${GW_NS} }]
  hostnames: ["${AR_HOST}"]
  rules:
    - matches: [{ path: { type: PathPrefix, value: / } }]
      backendRefs: [{ name: ${AR_SERVER_SVC}, port: ${AR_SERVER_PORT} }]
EOF
ok "HTTPRoutes applied"

step "Waiting for the gateway to be Programmed"
kc -n "$GW_NS" wait --for=condition=Programmed gateway/"$GW_NAME" --timeout=120s >/dev/null 2>&1 \
  && ok "gateway Programmed" || warn "gateway not Programmed in 2m"

for _ in $(seq 1 60); do
  curl -sf -m2 -o /dev/null "http://${KEYCLOAK_HOST}/realms/${KEYCLOAK_REALM}/.well-known/openid-configuration" && break
  sleep 2
done
curl -sf -m2 -o /dev/null "http://${KEYCLOAK_HOST}/realms/${KEYCLOAK_REALM}/.well-known/openid-configuration" \
  && ok "issuer ${KEYCLOAK_ISSUER} reachable from the host through the gateway" \
  || warn "issuer not reachable yet at ${KEYCLOAK_ISSUER}"
echo "  Next: ./scripts/24-agentregistry.sh" >&2
