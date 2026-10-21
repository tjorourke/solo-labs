#!/usr/bin/env bash
# e2e.sh: the whole lab, unattended, with assertions. Exits non-zero on any
# failed assertion. Runs the same numbered scripts a reader runs by hand, and
# checks the probe matrix after each policy:
#
#                         checkout GET  checkout DELETE  reporting GET  legacy GET  checkout DELETE+JWT  reporting DELETE+JWT
#   enrolled, no policy   200           200              200            200
#   1 STRICT              200           200              200            000
#   2 L4 authz            200           200              000            000
#   waypoint, L4 revised  200           200              200            000
#   3 L7 authz            200           403              403            000
#   4 JWT (Flightbay)     200           403              403            000         200                  200
#   4 JWT (tightened)     200           403              403            000         200                  403
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
      warn "$label: got '$got', want '$want' after ${timeout}s"; FAILS=$((FAILS+1)); return 1
    fi
    sleep 3
  done
}
JWT="$(cat "$LAB_ROOT/jwt/demo.jwt")"
FULL=1; [[ "${1:-}" == "--test" ]] && FULL=0

# The mesh-level checks hold at every stage, so they run in both modes.
assert_mesh() {
  assert "shop dataplane-mode label" "$(kc get ns "$NS_SHOP" -o jsonpath='{.metadata.labels.istio\.io/dataplane-mode}')" ambient
  assert "no sidecar containers on the app pods" "$(kc -n "$NS_SHOP" get pods -l 'app in (catalog,checkout,reporting)' -o jsonpath='{range .items[*]}{.spec.containers[*].name}{"\n"}{end}' | grep -c istio-proxy || true)" 0
  assert "ztunnel per node" "$(kc -n "$ISTIO_SYSTEM_NS" get ds ztunnel -o jsonpath='{.status.numberReady}')" "$(kc get nodes --no-headers | wc -l | tr -d ' ')"
  assert "ztunnel-config: app pods on HBONE" "$(ic ztunnel-config workloads --workload-namespace "$NS_SHOP" 2>/dev/null | awk 'NR>1 && $2 ~ /^(catalog|checkout|reporting)-/ {print $6}' | sort -u | tr '\n' ' ' | sed 's/ $//')" HBONE
}

if (( FULL )); then
"$SCRIPT_DIR/01-setup.sh"
"$SCRIPT_DIR/02-deploy-apps.sh"

step "ASSERT: enrolled, no policy"
assert_mesh
poll_code "checkout GET"   60 200 "$NS_SHOP" checkout GET
poll_code "checkout DELETE" 30 200 "$NS_SHOP" checkout DELETE
poll_code "reporting GET"  30 200 "$NS_SHOP" reporting GET
poll_code "legacy GET"     30 200 "$NS_LEGACY" legacy GET

"$SCRIPT_DIR/03-strict-mtls.sh"
step "ASSERT: policy 1, STRICT"
poll_code "legacy GET reset"  60 000 "$NS_LEGACY" legacy GET
poll_code "checkout GET"      30 200 "$NS_SHOP" checkout GET
poll_code "reporting GET"     30 200 "$NS_SHOP" reporting GET

"$SCRIPT_DIR/04-l4-authz.sh"
step "ASSERT: policy 2, L4 authz"
poll_code "reporting GET reset" 60 000 "$NS_SHOP" reporting GET
poll_code "checkout GET"        30 200 "$NS_SHOP" checkout GET
poll_code "checkout DELETE (L4 cannot see the method)" 30 200 "$NS_SHOP" checkout DELETE
poll_code "legacy GET reset"    30 000 "$NS_LEGACY" legacy GET

"$SCRIPT_DIR/05-waypoint.sh"
step "ASSERT: waypoint in place, L4 policy revised"
assert "exactly one waypoint pod" "$(kc -n "$NS_SHOP" get pods -l gateway.networking.k8s.io/gateway-name="$WAYPOINT_NAME" --no-headers | grep -c Running || true)" 1
assert "shop uses the waypoint" "$(kc get ns "$NS_SHOP" -o jsonpath='{.metadata.labels.istio\.io/use-waypoint}')" "$WAYPOINT_NAME"
assert "catalog-require-waypoint admits the waypoint" "$(kc -n "$NS_SHOP" get authorizationpolicy catalog-require-waypoint -o jsonpath='{.spec.rules[0].from[0].source.principals[0]}')" "cluster.local/ns/shop/sa/$WAYPOINT_NAME"
assert "catalog-l4 deleted" "$(kc -n "$NS_SHOP" get authorizationpolicy catalog-l4 --no-headers --ignore-not-found | wc -l | tr -d ' ')" 0
poll_code "checkout GET"    60 200 "$NS_SHOP" checkout GET
poll_code "reporting GET (no L7 policy yet)" 30 200 "$NS_SHOP" reporting GET
poll_code "legacy GET reset" 30 000 "$NS_LEGACY" legacy GET

"$SCRIPT_DIR/06-l7-authz.sh"
step "ASSERT: policy 3, L7 authz on the waypoint"
poll_code "checkout GET"           60 200 "$NS_SHOP" checkout GET
poll_code "checkout DELETE 403"    30 403 "$NS_SHOP" checkout DELETE
poll_code "reporting GET 403"      30 403 "$NS_SHOP" reporting GET
poll_code "legacy GET reset"       30 000 "$NS_LEGACY" legacy GET

"$SCRIPT_DIR/07-jwt.sh"
fi  # FULL

# a call to the pod IP skips a service-attached waypoint; the L4 policy is what refuses it
pod_ip="$(kc -n "$NS_SHOP" get pod -l app=catalog -o jsonpath='{.items[0].status.podIP}')"
direct_code() { kc -n "$NS_SHOP" exec deploy/checkout -- curl -s -o /dev/null -w '%{http_code}' -X DELETE --max-time 5 "http://${pod_ip}:8080/anything" 2>/dev/null || true; }
step "ASSERT: waypoint bypass via pod IP is refused at L4"
assert "checkout DELETE direct to pod IP" "$(direct_code)" 000

step "ASSERT: end state (all four policies)"
assert "catalog-strict-mtls is STRICT" "$(kc -n "$NS_SHOP" get peerauthentication catalog-strict-mtls -o jsonpath='{.spec.mtls.mode}')" STRICT
assert_mesh
assert "exactly one waypoint pod" "$(kc -n "$NS_SHOP" get pods -l gateway.networking.k8s.io/gateway-name="$WAYPOINT_NAME" --no-headers | grep -c Running || true)" 1
assert "catalog-require-waypoint admits the waypoint" "$(kc -n "$NS_SHOP" get authorizationpolicy catalog-require-waypoint -o jsonpath='{.spec.rules[0].from[0].source.principals[0]}')" "cluster.local/ns/shop/sa/$WAYPOINT_NAME"
poll_code "checkout DELETE, no token, 403"     60 403 "$NS_SHOP" checkout DELETE
poll_code "checkout DELETE, bad token, 401"    30 401 "$NS_SHOP" checkout DELETE -H 'Authorization: Bearer not.a.token'
poll_code "checkout DELETE, signed token, 200" 30 200 "$NS_SHOP" checkout DELETE -H "Authorization: Bearer $JWT"
poll_code "reporting DELETE, signed token, 403" 30 403 "$NS_SHOP" reporting DELETE -H "Authorization: Bearer $JWT"
poll_code "checkout GET still 200"             30 200 "$NS_SHOP" checkout GET
poll_code "legacy GET still reset"             30 000 "$NS_LEGACY" legacy GET

echo
if (( FAILS > 0 )); then
  die "e2e: $FAILS assertion(s) failed"
fi
ok "e2e: every assertion passed on Istio $ISTIO_VERSION (upstream OSS)"
