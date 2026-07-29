#!/usr/bin/env bash
# e2e.sh — the whole lab, automated, with assertions. Exits non-zero on any
# failed assertion.
#
#   1. Sidecar baseline: kind + upstream Istio (sidecar mode), apps in four
#      namespaces, STRICT mTLS, DR/VS canary 100% v1, GET-only L7 authz
#      enforced by sidecars, redis L4 authz by identity
#   2. Ambient dataplane arrives UNDER LOAD (istiod profile=ambient + cni +
#      ztunnel) — fortio must score 100%; then one roll of every app namespace
#      so re-injected sidecars advertise HBONE
#   3. petstore-data migrates (label flip, NO waypoint): PONG stream survives,
#      L4 authz still enforced by ztunnel
#   4. Canary modernised: per-version Services + HTTPRoute replace the DR/VS
#      subset split (waypoints do not do subsets) — a no-op for live traffic
#   5. ONE cluster-wide waypoint deployed in mesh-infra (allowedRoutes: All)
#   6. petstore + petstore-orders migrate behind it UNDER LOAD (targetRefs
#      policies first, then the label flips) — and the community gap shows:
#      a caller still on a sidecar bypasses the waypoint's GET-only rule
#   7. petstore-clients migrates: the same DELETE now comes back 403 — the
#      waypoint enforces for ambient callers; canary shifts live via HTTPRoute
#   8. Rollback: petstore-orders goes BACK to sidecars with one label flip
#      (selector policy restored), then forward again — the switch works in
#      both directions
#   9. End state: zero sidecars, ztunnel per node, exactly ONE waypoint pod
#      for the whole cluster
#
#   ./scripts/e2e.sh          # everything upstream OSS — no licence, no auth
# Teardown: kind delete cluster --name ambient-oss
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
require istioctl

FAILS=0
assert() { # assert <label> <got> <want>
  if [[ "$2" == "$3" ]]; then ok "$1: $2"; else warn "$1: got '$2', want '$3'"; FAILS=$((FAILS+1)); fi
}
assert_contains() { # assert_contains <label> <haystack> <needle>
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else warn "$1: '$3' not found in '$2'"; FAILS=$((FAILS+1)); fi
}
# poll <label> <timeout-s> <cmd...> — until cmd exits 0
poll() {
  local label="$1" timeout="$2"; shift 2
  local start; start="$(date +%s)"
  while true; do
    if "$@" >/dev/null 2>&1; then ok "$label"; return 0; fi
    if (( $(date +%s) - start > timeout )); then warn "$label: timed out after ${timeout}s"; FAILS=$((FAILS+1)); return 1; fi
    sleep 5
  done
}

# HTTP status code of a request from checkout
curl_code() { # <method> <url>
  kc -n "$NS_CLIENTS" exec deploy/checkout -c checkout -- \
    curl -s -o /dev/null -w '%{http_code}' -X "$1" --max-time 5 "$2" 2>/dev/null || true
}
# fortio scoreboard: <seconds> of load against catalog, return the Code lines
fortio_run() { # <seconds>
  kc -n "$NS_CLIENTS" exec deploy/fortio -c fortio -- \
    fortio load -c 4 -qps 25 -t "${1}s" -quiet \
    "http://catalog.${NS_APP}/" 2>&1 | grep "Code " || true
}
# background fortio load; prints tmpfile, pid via globals
fortio_bg() { # <seconds>
  __fortio_out="$(mktemp)"
  kc -n "$NS_CLIENTS" exec deploy/fortio -c fortio -- \
    fortio load -c 4 -qps 25 -t "${1}s" -quiet \
    "http://catalog.${NS_APP}/" >"$__fortio_out" 2>&1 &
  __fortio_pid=$!
}
# count of v2 answers out of 30 GETs from checkout
v2_of_30() {
  kc -n "$NS_CLIENTS" exec deploy/checkout -c checkout -- \
    sh -c 'i=0; while [ $i -lt 30 ]; do curl -s --max-time 5 http://catalog.petstore/; i=$((i+1)); done' 2>/dev/null \
    | grep -c '"version":"v2"' || true
}
# redis PING from the checkout identity: allowed → "+PONG", denied → empty.
# (An L4 deny does not reset the client's connection — the client-side proxy
# accepts locally — so probe with a payload, never with exit codes.)
redis_ping_from_checkout() {
  kc -n "$NS_CLIENTS" exec deploy/checkout -c checkout -- \
    sh -c 'printf "PING\r\n" | nc -w 3 redis.petstore-data 6379' 2>/dev/null | tr -d '\r'
}
# all container names (regular + init) of the first pod matching a label.
# On k8s >=1.29 Istio injects istio-proxy as a NATIVE sidecar, i.e. an
# initContainer with restartPolicy Always — spec.containers alone misses it.
pod_containers() { # <ns> <label>
  kc -n "$1" get pods -l "$2" \
    -o jsonpath='{.items[0].spec.containers[*].name} {.items[0].spec.initContainers[*].name}'
}
# sidecar count across app namespaces (regular + init containers)
sidecar_count() {
  local n=0 ns
  for ns in "$NS_APP" "$NS_ORDERS" "$NS_DATA" "$NS_CLIENTS"; do
    n=$(( n + $(kc -n "$ns" get pods -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.name}{"\n"}{end}{range .spec.initContainers[*]}{.name}{"\n"}{end}{end}' 2>/dev/null | grep -c '^istio-proxy$' || true) ))
  done
  echo "$n"
}

step "1/9 · Sidecar baseline (kind + upstream Istio $ISTIO_VERSION, sidecar mode)"
"$SCRIPT_DIR/setup-cluster.sh"
kapply "$LAB_ROOT/yaml/00-namespaces.yaml"
kapply "$LAB_ROOT/yaml/10-apps/"
kapply "$LAB_ROOT/yaml/20-policies-sidecar/"
kc -n "$NS_APP"     rollout status deploy/catalog-v1 deploy/catalog-v2 deploy/data-client --timeout=300s >/dev/null
kc -n "$NS_ORDERS"  rollout status deploy/orders --timeout=180s >/dev/null
kc -n "$NS_DATA"    rollout status deploy/redis --timeout=180s >/dev/null
kc -n "$NS_CLIENTS" rollout status deploy/checkout deploy/fortio --timeout=180s >/dev/null
sleep 10
assert_contains "catalog pods carry a sidecar (native: initContainer)" "$(pod_containers "$NS_APP" app=catalog)" "istio-proxy"
assert "GET catalog (sidecar estate)" "$(curl_code GET "http://catalog.${NS_APP}/")" "200"
assert "GET orders" "$(curl_code GET "http://orders.${NS_ORDERS}/")" "200"
assert "DELETE catalog denied 403 (sidecar enforces GET-only)" "$(curl_code DELETE "http://catalog.${NS_APP}/")" "403"
assert "DELETE orders denied 403" "$(curl_code DELETE "http://orders.${NS_ORDERS}/")" "403"
assert "canary is 100% v1 (0 of 30 answers from v2)" "$(v2_of_30)" "0"
poll "redis PONG from the allowed identity" 60 sh -c "kubectl --context $CTX -n $NS_APP logs deploy/data-client --tail=1 | grep -q PONG"
DENIED="$(redis_ping_from_checkout)"
assert "redis silent to the checkout identity (L4 authz)" "$([[ "$DENIED" != *PONG* ]] && echo denied)" "denied"
SB="$(fortio_run 10)"; assert_contains "fortio baseline 100% 200s" "$SB" "(100.0 %)"

step "2/9 · Ambient dataplane arrives UNDER LOAD (helm: istiod ambient + cni + ztunnel)"
fortio_bg 150
"$SCRIPT_DIR/ambient-enable.sh"
wait "$__fortio_pid" || true
assert_contains "fortio 100% across the ambient standup" "$(grep 'Code ' "$__fortio_out")" "(100.0 %)"
rm -f "$__fortio_out"
assert "ztunnel runs on every node" \
  "$(kc -n "$ISTIO_SYSTEM_NS" get ds ztunnel -o jsonpath='{.status.numberReady}')" \
  "$(kc get nodes --no-headers | wc -l | tr -d ' ')"

step "3/9 · One roll of every app namespace (re-injected sidecars advertise HBONE)"
for ns in "$NS_APP" "$NS_ORDERS" "$NS_DATA" "$NS_CLIENTS"; do
  kc -n "$ns" rollout restart deploy >/dev/null
done
for ns in "$NS_APP" "$NS_ORDERS" "$NS_DATA" "$NS_CLIENTS"; do
  for d in $(kc -n "$ns" get deploy -o name); do
    kc -n "$ns" rollout status "$d" --timeout=300s >/dev/null
  done
done
sleep 10
HBONE_ENV="$(kc -n "$NS_APP" get pod -l app=catalog -o jsonpath='{.items[0].spec.initContainers[?(@.name=="istio-proxy")].env[?(@.name=="ISTIO_META_ENABLE_HBONE")].value}')"
assert "re-injected sidecar advertises HBONE" "$HBONE_ENV" "true"
assert "GET catalog still 200 after the roll" "$(curl_code GET "http://catalog.${NS_APP}/")" "200"

step "4/9 · petstore-data migrates — label flip, NO waypoint"
kc label ns "$NS_DATA" istio.io/dataplane-mode=ambient istio-injection- --overwrite >/dev/null
kc -n "$NS_DATA" rollout restart deploy/redis >/dev/null
kc -n "$NS_DATA" rollout status deploy/redis --timeout=180s >/dev/null
sleep 15
CONTAINERS="$(kc -n "$NS_DATA" get pods -l app=redis -o jsonpath='{.items[0].spec.containers[*].name}')"
assert "redis has no sidecar" "$CONTAINERS" "redis"
poll "redis PONG still flowing (allowed identity, now via ztunnel)" 90 \
  sh -c "kubectl --context $CTX -n $NS_APP logs deploy/data-client --tail=1 | grep -q PONG"
DENIED="$(redis_ping_from_checkout)"
assert "redis still silent to checkout (ztunnel enforces the same L4 authz)" "$([[ "$DENIED" != *PONG* ]] && echo denied)" "denied"

step "5/9 · Canary modernised: DR/VS subsets → per-version Services + HTTPRoute"
kapply "$LAB_ROOT/yaml/50-httproute/10-versioned-services.yaml"
kapply "$LAB_ROOT/yaml/50-httproute/20-catalog-httproute.yaml"
kapply "$LAB_ROOT/yaml/50-httproute/30-catalog-dr-nosubset.yaml"
kc -n "$NS_APP" delete virtualservice catalog >/dev/null
sleep 10
assert "canary still 100% v1 after the cutover" "$(v2_of_30)" "0"
SB="$(fortio_run 10)"; assert_contains "fortio 100% on the HTTPRoute" "$SB" "(100.0 %)"

step "6/9 · ONE waypoint for the whole cluster; petstore + orders behind it UNDER LOAD"
kapply "$LAB_ROOT/yaml/30-waypoint/cluster-waypoint.yaml"
poll "waypoint deployment programmed" 120 \
  kc -n "$NS_WAYPOINT" wait --for=condition=Programmed "gateway/$WAYPOINT_NAME" --timeout=5s
kc -n "$NS_WAYPOINT" rollout status deploy/"$WAYPOINT_NAME" --timeout=180s >/dev/null
# targetRefs policies BEFORE enrolment, then the selector versions go away
kapply "$LAB_ROOT/yaml/40-policies-waypoint/"
kc -n "$NS_APP" delete authorizationpolicy catalog-get-only >/dev/null
kc -n "$NS_ORDERS" delete authorizationpolicy orders-get-only >/dev/null
fortio_bg 120
for ns in "$NS_APP" "$NS_ORDERS"; do
  kc label ns "$ns" \
    istio.io/use-waypoint="$WAYPOINT_NAME" \
    istio.io/use-waypoint-namespace="$NS_WAYPOINT" \
    istio.io/dataplane-mode=ambient istio-injection- --overwrite >/dev/null
done
kc -n "$NS_APP" rollout restart deploy >/dev/null
kc -n "$NS_ORDERS" rollout restart deploy >/dev/null
for d in $(kc -n "$NS_APP" get deploy -o name); do kc -n "$NS_APP" rollout status "$d" --timeout=300s >/dev/null; done
kc -n "$NS_ORDERS" rollout status deploy/orders --timeout=180s >/dev/null
wait "$__fortio_pid" || true
assert_contains "fortio 100% across the waypoint enrolment" "$(grep 'Code ' "$__fortio_out")" "(100.0 %)"
rm -f "$__fortio_out"
CONTAINERS="$(kc -n "$NS_APP" get pods -l app=catalog -o jsonpath='{.items[0].spec.containers[*].name}')"
assert "catalog has no sidecar" "$CONTAINERS" "catalog"
sleep 10
SVC_WP="$(ic ztunnel-config service 2>/dev/null | grep -E "catalog|orders" | grep -c "$WAYPOINT_NAME" || true)"
[[ "$SVC_WP" -ge 2 ]] && ok "ztunnel maps catalog + orders services to $WAYPOINT_NAME ($SVC_WP entries)" \
  || { warn "expected >=2 services on the waypoint, got $SVC_WP"; FAILS=$((FAILS+1)); }
assert "GET catalog via waypoint" "$(curl_code GET "http://catalog.${NS_APP}/")" "200"
assert "GET orders via the SAME waypoint" "$(curl_code GET "http://orders.${NS_ORDERS}/")" "200"
# The community gap, shown live: checkout still has a sidecar, and community
# sidecars do not route through waypoints — so the GET-only rule (now waypoint
# enforced) no longer applies to it.
assert "DELETE catalog from the SIDECAR caller now 200 (community gap: sidecars bypass waypoints)" \
  "$(curl_code DELETE "http://catalog.${NS_APP}/")" "200"

step "7/9 · petstore-clients migrates — the waypoint now enforces for its calls"
kc label ns "$NS_CLIENTS" istio.io/dataplane-mode=ambient istio-injection- --overwrite >/dev/null
kc -n "$NS_CLIENTS" rollout restart deploy >/dev/null
kc -n "$NS_CLIENTS" rollout status deploy/checkout deploy/fortio --timeout=180s >/dev/null
sleep 15
assert "GET catalog (ambient caller, via waypoint)" "$(curl_code GET "http://catalog.${NS_APP}/")" "200"
assert "DELETE catalog now denied 403 (waypoint enforces for ambient callers)" \
  "$(curl_code DELETE "http://catalog.${NS_APP}/")" "403"
assert "DELETE orders denied 403 by the SAME waypoint" \
  "$(curl_code DELETE "http://orders.${NS_ORDERS}/")" "403"
SB="$(fortio_run 10)"; assert_contains "fortio 100% via the waypoint" "$SB" "(100.0 %)"
# live canary shift on the HTTPRoute, enforced at the waypoint
kc -n "$NS_APP" patch httproute catalog --type=json -p='[
  {"op":"replace","path":"/spec/rules/0/backendRefs/0/weight","value":50},
  {"op":"replace","path":"/spec/rules/0/backendRefs/1/weight","value":50}
]' >/dev/null
sleep 5
V2="$(v2_of_30)"
[[ "$V2" -ge 5 && "$V2" -le 25 ]] && ok "canary shifted 50/50 at the waypoint ($V2 of 30 from v2)" \
  || { warn "50/50 shift looks wrong: $V2 of 30 from v2"; FAILS=$((FAILS+1)); }
kc -n "$NS_APP" patch httproute catalog --type=json -p='[
  {"op":"replace","path":"/spec/rules/0/backendRefs/0/weight","value":100},
  {"op":"replace","path":"/spec/rules/0/backendRefs/1/weight","value":0}
]' >/dev/null

step "8/9 · Rollback: petstore-orders goes BACK to sidecars, then forward again"
fortio_bg 90
kc label ns "$NS_ORDERS" istio-injection=enabled istio.io/dataplane-mode- \
  istio.io/use-waypoint- istio.io/use-waypoint-namespace- --overwrite >/dev/null
kc -n "$NS_ORDERS" rollout restart deploy/orders >/dev/null
kc -n "$NS_ORDERS" rollout status deploy/orders --timeout=180s >/dev/null
# sidecars are back → restore the selector policy, retire the targetRefs one
kapply "$LAB_ROOT/yaml/20-policies-sidecar/40-l7-authz-orders.yaml"
kc -n "$NS_ORDERS" delete authorizationpolicy orders-get-only-waypoint >/dev/null
wait "$__fortio_pid" || true
assert_contains "fortio 100% across the rollback (catalog untouched)" "$(grep 'Code ' "$__fortio_out")" "(100.0 %)"
rm -f "$__fortio_out"
sleep 10
assert_contains "orders pods carry a sidecar again (native: initContainer)" "$(pod_containers "$NS_ORDERS" app=orders)" "istio-proxy"
assert "GET orders 200 after rollback" "$(curl_code GET "http://orders.${NS_ORDERS}/")" "200"
assert "DELETE orders denied 403 again (sidecar enforces the selector policy)" \
  "$(curl_code DELETE "http://orders.${NS_ORDERS}/")" "403"
# …and forward again: the same switch, the other way
kapply "$LAB_ROOT/yaml/40-policies-waypoint/20-orders-authz-targetref.yaml"
kc -n "$NS_ORDERS" delete authorizationpolicy orders-get-only >/dev/null
kc label ns "$NS_ORDERS" \
  istio.io/use-waypoint="$WAYPOINT_NAME" \
  istio.io/use-waypoint-namespace="$NS_WAYPOINT" \
  istio.io/dataplane-mode=ambient istio-injection- --overwrite >/dev/null
kc -n "$NS_ORDERS" rollout restart deploy/orders >/dev/null
kc -n "$NS_ORDERS" rollout status deploy/orders --timeout=180s >/dev/null
sleep 10
assert "GET orders 200 after re-enrolment" "$(curl_code GET "http://orders.${NS_ORDERS}/")" "200"
assert "DELETE orders 403 via the waypoint again" "$(curl_code DELETE "http://orders.${NS_ORDERS}/")" "403"

step "9/9 · End state: zero sidecars, ztunnel per node, ONE waypoint pod"
assert "no sidecar containers left in the app namespaces" "$(sidecar_count)" "0"
WPODS="$(kc get pods -A -l gateway.networking.k8s.io/gateway-name -o name 2>/dev/null | wc -l | tr -d ' ')"
assert "exactly one waypoint pod for the whole cluster" "$WPODS" "1"
assert "GET catalog" "$(curl_code GET "http://catalog.${NS_APP}/")" "200"
poll "redis PONG still flowing at the end" 60 \
  sh -c "kubectl --context $CTX -n $NS_APP logs deploy/data-client --tail=1 | grep -q PONG"

echo
if (( FAILS == 0 )); then
  ok "E2E PASSED — sidecar→ambient by label, one waypoint for the cluster, rollback proven, zero dropped requests."
else
  warn "E2E FAILED — $FAILS assertion(s) failed"
  exit 1
fi
