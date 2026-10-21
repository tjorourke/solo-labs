#!/usr/bin/env bash
# e2e.sh: the whole lab, unattended, with assertions. Exits non-zero on any
# failed assertion. Runs the numbered scripts a reader runs, with one
# difference: Bookinfo is deployed by test-helpers/deploy-bookinfo.sh (the
# manifests Flightbay bundles), because the wizard cannot run unattended.
#
#                         reviews GET  reviews POST  demo-client GET  legacy GET  reviews POST+JWT  demo-client POST+JWT
#   Bookinfo, no policy   200          200           200              200
#   1 STRICT              200          200           200              000
#   2 L4 authz            503          503           503              000
#   2 require waypoint    200          200           200              000
#   3 L7 authz            200          403           403              000
#   4 JWT (Flightbay)     200          403           403              000         200               200
#   4 JWT (tightened)     200          403           403              000         200               403
#
#   ./scripts/e2e.sh            # build everything and assert after every step
#   ./scripts/e2e.sh --test     # assert the END state of a cluster that is already up
# Teardown: ./scripts/99-teardown.sh (kind delete cluster --name ambient-policies-lab)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

FAILS=0
assert() { # assert <label> <got> <want>
  if [[ "$2" == "$3" ]]; then ok "$1: $2"; else warn "$1: got '$2', want '$3'"; FAILS=$((FAILS+1)); fi
}
# poll_code <label> <timeout-s> <want> <curl_code args...>: a policy takes a
# moment to reach ztunnel or the waypoint, so wait for the expected code.
poll_code() {
  local label="$1" timeout="$2" want="$3"; shift 3
  local start got; start="$(date +%s)"
  while true; do
    got="$(curl_code "$@")"
    if [[ "$got" == "$want" ]]; then ok "$label: $got"; return 0; fi
    if (( $(date +%s) - start > timeout )); then
      warn "$label: got '$got', want '$want' after ${timeout}s"; FAILS=$((FAILS+1)); return 0
    fi
    sleep 3
  done
}
BODY=(-H 'Content-Type: application/json' -d '{"reviewerId":"e2e","productId":0,"rating":4}')
TOK="Authorization: Bearer $(cat "$LAB_ROOT/jwt/demo.jwt")"
FULL=1; [[ "${1:-}" == "--test" ]] && FULL=0

assert_mesh() {
  assert "bookinfo dataplane-mode label" "$(kc get ns "$NS_APP" -o jsonpath='{.metadata.labels.istio\.io/dataplane-mode}')" ambient
  assert "bookinfo use-waypoint label" "$(kc get ns "$NS_APP" -o jsonpath='{.metadata.labels.istio\.io/use-waypoint}')" "$WAYPOINT_NAME"
  assert "no sidecar containers on the Bookinfo pods" "$(kc -n "$NS_APP" get pods -l '!gateway.networking.k8s.io/gateway-name' -o jsonpath='{range .items[*]}{.spec.containers[*].name}{"\n"}{end}' | grep -c istio-proxy || true)" 0
  assert "ztunnel per node" "$(kc -n "$ISTIO_SYSTEM_NS" get ds ztunnel -o jsonpath='{.status.numberReady}')" "$(kc get nodes --no-headers | wc -l | tr -d ' ')"
  assert "ztunnel-config: Bookinfo pods on HBONE" "$(ic ztunnel-config workloads --workload-namespace "$NS_APP" 2>/dev/null | awk 'NR>1 && $2 ~ /^(details|ratings|reviews|productpage)-/ {print $6}' | sort -u | tr '\n' ' ' | sed 's/ $//')" HBONE
  assert "exactly one waypoint pod" "$(kc -n "$NS_APP" get pods -l gateway.networking.k8s.io/gateway-name="$WAYPOINT_NAME" --no-headers | grep -c Running || true)" 1
}

if (( FULL )); then
"$SCRIPT_DIR/01-setup.sh"
BOOKINFO_HELPER=1 "$SCRIPT_DIR/02-check-bookinfo.sh"

step "ASSERT: Bookinfo enrolled, no policy"
assert_mesh
poll_code "reviews GET"     90 200 "$NS_APP" reviews-v2 GET
poll_code "reviews POST"    30 200 "$NS_APP" reviews-v2 POST "${BODY[@]}"
poll_code "demo-client GET" 30 200 "$NS_APP" demo-client GET
poll_code "legacy GET"      30 200 "$NS_LEGACY" legacy GET

"$SCRIPT_DIR/03-strict-mtls.sh"
step "ASSERT: policy 1, STRICT"
poll_code "legacy GET reset" 60 000 "$NS_LEGACY" legacy GET
poll_code "reviews GET"      30 200 "$NS_APP" reviews-v2 GET
poll_code "demo-client GET"  30 200 "$NS_APP" demo-client GET

# 04 applies ratings-l4, restarts the waypoint, probes (503), then fixes it.
# Check the 503 stage by doing the first part here, the way 04 starts.
kc apply -f "$LAB_ROOT/yaml/20-policies/20-l4-authz-ratings.yaml" >/dev/null
kc -n "$NS_APP" rollout restart "deploy/$WAYPOINT_NAME" >/dev/null
kc -n "$NS_APP" rollout status "deploy/$WAYPOINT_NAME" --timeout=120s >/dev/null
step "ASSERT: policy 2, L4 authz refuses the waypoint"
poll_code "reviews GET 503"     60 503 "$NS_APP" reviews-v2 GET
poll_code "demo-client GET 503" 30 503 "$NS_APP" demo-client GET
"$SCRIPT_DIR/04-l4-authz.sh"
step "ASSERT: policy 2 revised: only the waypoint reaches ratings"
assert "ratings-require-waypoint admits the waypoint" "$(kc -n "$NS_APP" get authorizationpolicy ratings-require-waypoint -o jsonpath='{.spec.rules[0].from[0].source.principals[0]}')" "cluster.local/ns/$NS_APP/sa/$WAYPOINT_NAME"
assert "ratings-l4 deleted" "$(kc -n "$NS_APP" get authorizationpolicy ratings-l4 --no-headers --ignore-not-found | wc -l | tr -d ' ')" 0
poll_code "reviews GET"         60 200 "$NS_APP" reviews-v2 GET
poll_code "demo-client GET (no L7 policy yet)" 30 200 "$NS_APP" demo-client GET

"$SCRIPT_DIR/05-l7-authz.sh"
step "ASSERT: policy 3, L7 authz on the waypoint"
poll_code "reviews GET"         60 200 "$NS_APP" reviews-v2 GET
poll_code "reviews POST 403"    30 403 "$NS_APP" reviews-v2 POST "${BODY[@]}"
poll_code "demo-client GET 403" 30 403 "$NS_APP" demo-client GET

"$SCRIPT_DIR/06-jwt.sh"
fi  # FULL

pod_ip="$(kc -n "$NS_APP" get pod -l app=ratings -o jsonpath='{.items[0].status.podIP}')"
step "ASSERT: waypoint bypass via pod IP is refused at L4"
assert "reviews GET direct to pod IP" "$(kc -n "$NS_APP" exec deploy/reviews-v2 -- curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${pod_ip}:9080/ratings/0" 2>/dev/null || true)" 000

step "ASSERT: end state (all four policies)"
assert "ratings-strict-mtls is STRICT" "$(kc -n "$NS_APP" get peerauthentication ratings-strict-mtls -o jsonpath='{.spec.mtls.mode}')" STRICT
assert_mesh
poll_code "reviews POST, no token, 403"         60 403 "$NS_APP" reviews-v2 POST "${BODY[@]}"
poll_code "reviews POST, bad token, 401"        30 401 "$NS_APP" reviews-v2 POST "${BODY[@]}" -H 'Authorization: Bearer not.a.token'
poll_code "reviews POST, signed token, 200"     30 200 "$NS_APP" reviews-v2 POST "${BODY[@]}" -H "$TOK"
poll_code "demo-client POST, signed token, 403" 30 403 "$NS_APP" demo-client POST "${BODY[@]}" -H "$TOK"
poll_code "reviews GET still 200"               30 200 "$NS_APP" reviews-v2 GET
poll_code "demo-client GET still 403"           30 403 "$NS_APP" demo-client GET
poll_code "legacy GET still reset"              30 000 "$NS_LEGACY" legacy GET
assert "productpage still 200" "$(kc -n "$NS_APP" exec deploy/demo-client -- curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://productpage:9080/productpage 2>/dev/null || true)" 200

echo
if (( FAILS > 0 )); then
  die "e2e: $FAILS assertion(s) failed"
fi
ok "e2e: every assertion passed on Istio $ISTIO_VERSION"
