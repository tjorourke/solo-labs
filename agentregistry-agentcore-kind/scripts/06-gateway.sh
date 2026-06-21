#!/usr/bin/env bash
# 06-gateway.sh — expose the consoles at http://*.localtest.me through an
# agentgateway INGRESS Gateway, so there are no kubectl port-forwards. Runs after
# 05-waypoint.sh (which installs the enterprise-agentgateway GatewayClass).
#
# A Gateway (gatewayClassName: enterprise-agentgateway) with an HTTP :80 listener,
# its Service forced to NodePort 30080 (kind maps host :80 -> 30080), plus three
# HTTPRoutes:
#   keycloak.localtest.me      -> keycloak.keycloak:80                 (OIDC issuer)
#   agentregistry.localtest.me -> agentregistry-enterprise-server:12121 (AR UI/API)
#   kagent.localtest.me        -> solo-enterprise-ui:80                 (Enterprise UI)
# *.localtest.me resolves to 127.0.0.1 via public DNS, so the host reaches the
# gateway with no /etc/hosts and no port-forward.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

kc get gatewayclass enterprise-agentgateway >/dev/null 2>&1 \
  || die "GatewayClass enterprise-agentgateway not found — run ./scripts/05-waypoint.sh first"

step "Creating the ingress Gateway + HTTPRoutes"
kc create namespace "$GW_NS" --dry-run=client -o yaml | kc apply -f - >/dev/null
kc apply -f - >/dev/null <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${GW_NAME}
  namespace: ${GW_NS}
spec:
  gatewayClassName: enterprise-agentgateway
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces: { from: All }
---
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
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: kagent-ui, namespace: ${SOLO_MGMT_NS} }
spec:
  parentRefs: [{ name: ${GW_NAME}, namespace: ${GW_NS} }]
  hostnames: ["${KAGENT_UI_HOST}"]
  rules:
    - matches: [{ path: { type: PathPrefix, value: / } }]
      backendRefs: [{ name: solo-enterprise-ui, port: 80 }]
EOF
ok "Gateway ${GW_NAME} + HTTPRoutes applied"

step "Pinning the gateway Service to NodePort ${GW_HTTP_NODEPORT} (kind host :80)"
# The gateway controller provisions a Service for the Gateway; force it to NodePort
# on 30080 so kind's extraPortMapping (host 80 -> 30080) reaches it.
GW_SVC=""
for _ in $(seq 1 40); do
  GW_SVC="$(kc -n "$GW_NS" get svc -l gateway.networking.k8s.io/gateway-name="$GW_NAME" -o name 2>/dev/null | head -1)"
  [[ -n "$GW_SVC" ]] && break; sleep 3
done
if [[ -n "$GW_SVC" ]]; then
  kc -n "$GW_NS" patch "$GW_SVC" --type=json -p "[
    {\"op\":\"replace\",\"path\":\"/spec/type\",\"value\":\"NodePort\"},
    {\"op\":\"replace\",\"path\":\"/spec/ports/0/nodePort\",\"value\":${GW_HTTP_NODEPORT}}
  ]" >/dev/null 2>&1 \
    && ok "${GW_SVC} -> NodePort ${GW_HTTP_NODEPORT}" \
    || warn "could not patch ${GW_SVC} to NodePort ${GW_HTTP_NODEPORT}; check the gateway Service"
else
  warn "gateway Service not found for ${GW_NAME}; the consoles won't be reachable on host :80"
fi

step "Waiting for the gateway to accept routes"
kc -n "$GW_NS" wait --for=condition=Programmed gateway/"$GW_NAME" --timeout=120s >/dev/null 2>&1 \
  && ok "gateway Programmed" || warn "gateway not Programmed in 2m — check: kc -n $GW_NS get gateway $GW_NAME"

step "Ingress ready — consoles at http://*.localtest.me"
echo "  AgentRegistry : http://${AR_HOST}" >&2
echo "  Enterprise UI : http://${KAGENT_UI_HOST}" >&2
echo "  Keycloak      : http://${KEYCLOAK_HOST}" >&2
echo "  Next: ./scripts/connect.sh (arctl login) + ./scripts/04b-register-runtime.sh" >&2
