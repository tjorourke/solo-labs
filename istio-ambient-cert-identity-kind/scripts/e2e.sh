#!/usr/bin/env bash
# e2e.sh — the whole lab, automated, with assertions. Stands up the mesh,
# deploys the petshop, proves L4 identity authz (allow/deny + the shared-SA
# gap), the L7 JWT authz matrix at a waypoint with Keycloak, then flips
# ENABLE_WORKLOAD_CLAIMS on ztunnel so workload claims close the shared-SA gap
# at L4. Exits non-zero on any failed assertion.
#
#   ./scripts/e2e.sh SECRETS_FILE=... (or export SOLO_ISTIO_LICENSE_KEY)
# Needs docker, kind, kubectl, helm, istioctl, gcloud (authenticated).
# Teardown: kind delete cluster --name cert-identity
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FAILS=0
assert() { # assert <label> <got> <want>
  if [[ "$2" == "$3" ]]; then ok "$1: $2"; else warn "$1: got '$2', want '$3'"; FAILS=$((FAILS+1)); fi
}
code_of() { kc -n "$NS_APP" logs "deploy/$1" --tail=1 2>/dev/null | grep -oE '[0-9]{3,6}$'; }

step "1/9 · Stand up the mesh"
"$SCRIPT_DIR/setup-cluster.sh"

step "2/9 · Deploy the petshop"
kapply "$LAB_ROOT/yaml/10-app/"
kc -n "$NS_APP" rollout status deploy/petstore deploy/storefront deploy/analytics deploy/checkout-blue deploy/checkout-green --timeout=180s >/dev/null
# kick off Keycloak now so it is warm by the JWT step (no mid-run wait)
kapply "$LAB_ROOT/yaml/40-idp/keycloak.yaml"
ok "petshop deployed; Keycloak starting in the background"

step "3/9 · Identity is the certificate"
NODE="$(kc -n "$NS_APP" get pods -o jsonpath='{.items[0].spec.nodeName}')"
ZT="$(kc -n "$ISTIO_SYSTEM_NS" get pods -l app=ztunnel --field-selector "spec.nodeName=${NODE}" -o jsonpath='{.items[0].metadata.name}')"
CERTS="$(ic ztunnel-config certificate "$ZT.$ISTIO_SYSTEM_NS" 2>/dev/null | grep -c "ns/$NS_APP/sa/.*Leaf")"
assert "distinct leaf SVIDs (petstore+storefront+analytics+checkout=4)" "$CERTS" "4"

step "4/9 · L4 authz: allow storefront only"
kapply "$LAB_ROOT/yaml/20-policy/10-allow-storefront.yaml"; sleep 14
assert "storefront allowed" "$(code_of storefront)" "200"
[[ "$(code_of analytics)" == "000000" ]] && ok "analytics denied: 000000" || { warn "analytics not denied: $(code_of analytics)"; FAILS=$((FAILS+1)); }

step "5/9 · The shared-SA gap: allow sa/checkout"
kapply "$LAB_ROOT/yaml/20-policy/20-allow-checkout.yaml"; sleep 14
assert "checkout-blue allowed"  "$(code_of checkout-blue)"  "200"
assert "checkout-green allowed" "$(code_of checkout-green)" "200"
[[ "$(code_of analytics)" == "000000" ]] && ok "analytics still denied" || { warn "analytics leaked: $(code_of analytics)"; FAILS=$((FAILS+1)); }

step "6/9 · More of the L4 match surface: namespace (when) + DENY precedence"
wh_code() { kc -n warehouse logs deploy/warehouse-svc --tail=1 2>/dev/null | grep -oE '[0-9]{3,6}$'; }
kapply "$LAB_ROOT/yaml/25-l4-surface/00-warehouse.yaml"
kc -n warehouse rollout status deploy/warehouse-svc --timeout=90s >/dev/null
# namespace ALLOW via a CEL when-clause on source.namespace: cross-ns warehouse-svc is denied
kapply "$LAB_ROOT/yaml/25-l4-surface/10-allow-petshop-namespace.yaml"; sleep 14
assert "petshop caller allowed (when source.namespace)" "$(code_of storefront)" "200"
assert "cross-ns warehouse denied" "$(wh_code)" "000000"
# DENY precedence: analytics blocked even under the namespace ALLOW
kapply "$LAB_ROOT/yaml/25-l4-surface/20-deny-analytics.yaml"; sleep 14
assert "DENY beats ALLOW (analytics)" "$(code_of analytics)" "000000"
assert "storefront still allowed"     "$(code_of storefront)" "200"
# close the loop: widen the namespace ALLOW to admit warehouse (DENY still wins)
kapply "$LAB_ROOT/yaml/25-l4-surface/30-allow-petshop-and-warehouse.yaml"; sleep 14
assert "warehouse allowed in (widened when)" "$(wh_code)" "200"
assert "analytics still denied (DENY > ALLOW)" "$(code_of analytics)" "000000"
kc -n "$NS_APP" delete authorizationpolicy l4-allow-petshop-namespace l4-deny-analytics --ignore-not-found >/dev/null

step "7/9 · agentgateway waypoint + Keycloak IdP"
kc -n "$NS_APP" delete authorizationpolicy allow-storefront allow-checkout --ignore-not-found >/dev/null
"$SCRIPT_DIR/agw-install.sh"
kapply "$LAB_ROOT/yaml/50-l7/10-waypoint.yaml"
kc label namespace "$NS_APP" istio.io/use-waypoint=petshop-waypoint --overwrite >/dev/null
sleep 5
kc -n "$NS_APP" rollout status deploy/petshop-waypoint --timeout=150s >/dev/null
kc -n keycloak rollout status deploy/keycloak --timeout=240s >/dev/null   # applied early in step 2
ok "agentgateway waypoint + keycloak ready"

step "8/9 · L7 JWT authz matrix"
kapply "$LAB_ROOT/yaml/50-l7/20-jwt.yaml"; sleep 12
KCURL=http://keycloak.keycloak.svc.cluster.local:8080/realms/petshop/protocol/openid-connect/token
tok() { kc -n "$NS_APP" exec deploy/storefront -- sh -c "curl -s -m10 -d grant_type=password -d client_id=petshop -d username=$1 -d password=$1 -d scope=openid $KCURL" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p'; }
call() { kc -n "$NS_APP" exec deploy/storefront -- sh -c "$1"; }
ALICE=$(tok alice); BOB=$(tok bob)
assert "no token -> GET 401 (agw authn)" "$(call "curl -s -o /dev/null -w '%{http_code}' -m5 http://petstore:8080/pets")" "401"
assert "alice -> GET 200"           "$(call "curl -s -o /dev/null -w '%{http_code}' -m5 -H 'Authorization: Bearer $ALICE' http://petstore:8080/pets")" "200"
assert "alice(user) -> DELETE 403"  "$(call "curl -s -o /dev/null -w '%{http_code}' -m5 -X DELETE -H 'Authorization: Bearer $ALICE' http://petstore:8080/pets/1")" "403"
assert "bob(admin) -> DELETE 200"   "$(call "curl -s -o /dev/null -w '%{http_code}' -m5 -X DELETE -H 'Authorization: Bearer $BOB' http://petstore:8080/pets/1")" "200"

# 8b: routing at the same waypoint — canary split + header shift, JWT still enforced
kapply "$LAB_ROOT/yaml/50-l7/30-petstore-v2.yaml"
kc -n "$NS_APP" rollout status deploy/petstore-v2 --timeout=120s >/dev/null
kapply "$LAB_ROOT/yaml/50-l7/40-route-split.yaml"; sleep 10
served() { call "curl -s -m5 -H 'Authorization: Bearer $ALICE' $1 http://petstore:8080/pets" | grep -o '"served_by": "petstore[^"]*"' | grep -q "petstore-v2" && echo v2 || echo v1; }
BETA_V2=0; for _ in 1 2 3; do [[ "$(served "-H 'x-beta: true'")" == "v2" ]] && BETA_V2=$((BETA_V2+1)); done
assert "x-beta header -> always v2 (3/3)" "$BETA_V2" "3"
V1=0; V2=0
for _ in $(seq 1 20); do if [[ "$(served "")" == "v2" ]]; then V2=$((V2+1)); else V1=$((V1+1)); fi; done
ok "canary split over 20 requests: v1=$V1 v2=$V2 (weights 90/10)"
[[ $V1 -gt $V2 ]] && ok "v1 majority holds" || { warn "v1 not majority: v1=$V1 v2=$V2"; FAILS=$((FAILS+1)); }
assert "no token on beta route -> 401" "$(call "curl -s -o /dev/null -w '%{http_code}' -m5 -H 'x-beta: true' http://petstore:8080/pets")" "401"

# 8c: rate limit BY WORKLOAD IDENTITY — storefront capped, checkout untouched (same token)
kapply "$LAB_ROOT/yaml/50-l7/50-ratelimit.yaml"; sleep 8
SF_CODES="$(call "for i in 1 2 3 4 5 6 7 8; do curl -s -o /dev/null -w '%{http_code} ' -m5 -H 'Authorization: Bearer $ALICE' http://petstore:8080/pets; done")"
[[ "$SF_CODES" == *"429"* ]] && ok "storefront rate limited: $SF_CODES" || { warn "storefront never hit 429: $SF_CODES"; FAILS=$((FAILS+1)); }
BL_CODES="$(kc -n "$NS_APP" exec deploy/checkout-blue -- sh -c "for i in 1 2 3 4 5 6 7 8; do curl -s -o /dev/null -w '%{http_code} ' -m5 -H 'Authorization: Bearer $ALICE' http://petstore:8080/pets; done")"
[[ "$BL_CODES" == "200 200 200 200 200 200 200 200 " ]] && ok "checkout-blue unlimited (same token): $BL_CODES" || { warn "checkout-blue affected: $BL_CODES"; FAILS=$((FAILS+1)); }

step "9/9 · Workload claims (ENABLE_WORKLOAD_CLAIMS) close the shared-SA gap"
"$SCRIPT_DIR/claims-enable.sh"
kc -n "$NS_APP" patch deploy checkout-blue  -p '{"spec":{"template":{"metadata":{"annotations":{"solo.io.security-claims/tier":"gold"}}}}}' >/dev/null
kc -n "$NS_APP" patch deploy checkout-green -p '{"spec":{"template":{"metadata":{"annotations":{"solo.io.security-claims/tier":"silver"}}}}}' >/dev/null
kc -n "$NS_APP" rollout status deploy/checkout-blue deploy/checkout-green --timeout=120s >/dev/null
kapply "$LAB_ROOT/yaml/60-claims/10-allow-gold-checkout.yaml"
# fresh per-pod certs + the new policy take ~20-30s to converge after the
# rollout (green can also ride a connection from the brief no-policy window) —
# poll BOTH terminal states (bounded) instead of a fixed sleep
for _ in $(seq 1 24); do
  [[ "$(code_of checkout-blue)" == "200" && "$(code_of checkout-green)" == "000000" ]] && break
  sleep 5
done
# the claim is IN the cert: decode the otherName SAN on blue's per-pod cert
NODE="$(kc -n "$NS_APP" get pods -l app=checkout -o jsonpath='{.items[0].spec.nodeName}')"
ZT="$(kc -n "$ISTIO_SYSTEM_NS" get pods -l app=ztunnel --field-selector "spec.nodeName=${NODE}" -o jsonpath='{.items[0].metadata.name}')"
TIER="$(ic ztunnel-config certificates "$ZT.$ISTIO_SYSTEM_NS" -o json 2>/dev/null \
  | jq -r '.[] | select(.identity | contains("checkout-blue")) | .certChain[0].pem' | base64 -d \
  | openssl x509 -noout -text | grep -o '65865\.1\.1:.*' | cut -d: -f2 \
  | python3 -c 'import sys,base64,json; p=sys.stdin.read().strip(); print(json.loads(base64.urlsafe_b64decode(p+"="*(-len(p)%4)))["solo.io"]["security-claims"]["tier"])')"
assert "checkout-blue cert claim tier" "$TIER" "gold"
assert "checkout-blue (gold) allowed" "$(code_of checkout-blue)" "200"
[[ "$(code_of checkout-green)" == "000000" ]] && ok "checkout-green (silver) denied" || { warn "checkout-green not denied: $(code_of checkout-green)"; FAILS=$((FAILS+1)); }

echo
if [[ $FAILS -eq 0 ]]; then ok "E2E PASSED — all assertions green"; else die "E2E FAILED — $FAILS assertion(s) failed"; fi
