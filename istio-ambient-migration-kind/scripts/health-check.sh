#!/usr/bin/env bash
# health-check.sh — snapshot the mesh + app at any point in the migration:
# data-plane mode per namespace, pod sidecar counts, the canary split, the L7
# authz decisions, the L4 allow/deny, and a fortio run (the zero-downtime score).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

step "Mesh components (istio-system)"
kc -n "$ISTIO_SYSTEM_NS" get deploy,ds 2>/dev/null

step "Namespace data-plane mode"
kc get ns "$NS_APP" "$NS_DATA" "$NS_LEGACY" \
  -L istio.io/dataplane-mode -L istio-injection 2>/dev/null

step "Pods (READY column shows sidecar 2/2 vs ambient 1/1)"
for ns in "$NS_APP" "$NS_DATA" "$NS_LEGACY"; do kc get pods -n "$ns" 2>/dev/null; done

step "Waypoints"
kc get gateway -A 2>/dev/null | grep -E "NAME|waypoint" || echo "  (none)"

step "Routing objects in $NS_APP"
kc -n "$NS_APP" get httproute,virtualservice,destinationrule 2>/dev/null

step "Canary split (20 requests to catalog)"
kc -n "$NS_LEGACY" exec deploy/checkout -c checkout -- \
  sh -c 'for i in $(seq 1 20); do curl -s http://catalog.petstore/; echo; done' 2>/dev/null \
  | grep -o 'v[12]' | sort | uniq -c

step "L7 authz (via catalog): GET should be 200, DELETE 403"
kc -n "$NS_LEGACY" exec deploy/checkout -c checkout -- sh -c \
  'echo -n "  GET   -> "; curl -s -o /dev/null -w "%{http_code}\n" http://catalog.petstore/;
   echo -n "  DELETE-> "; curl -s -o /dev/null -w "%{http_code}\n" -X DELETE http://catalog.petstore/' 2>/dev/null

step "L4 authz on redis: catalog identity allowed, others denied"
echo -n "  data-client (allowed) -> "
kc -n "$NS_APP" exec deploy/data-client -c client -- sh -c 'timeout 5 redis-cli -h redis.petstore-data ping' 2>/dev/null
kc -n "$NS_LEGACY" delete pod l4test --ignore-not-found >/dev/null 2>&1
kc -n "$NS_LEGACY" run l4test --image=redis:7-alpine \
  --overrides='{"spec":{"serviceAccountName":"checkout"}}' --restart=Never --command -- sleep 60 >/dev/null 2>&1
kc -n "$NS_LEGACY" wait --for=condition=Ready pod/l4test --timeout=40s >/dev/null 2>&1
echo -n "  checkout    (denied ) -> "
kc -n "$NS_LEGACY" exec l4test -c l4test -- sh -c 'timeout 6 redis-cli -h redis.petstore-data ping 2>&1' 2>/dev/null
kc -n "$NS_LEGACY" delete pod l4test --ignore-not-found >/dev/null 2>&1

step "Zero-downtime score (fortio, 800 requests)"
kc -n "$NS_LEGACY" exec deploy/fortio -c fortio -- \
  fortio load -c 8 -n 800 -qps 0 -quiet http://catalog.petstore/ 2>/dev/null | grep -E "Code "
