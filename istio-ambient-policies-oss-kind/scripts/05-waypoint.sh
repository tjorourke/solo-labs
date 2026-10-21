#!/usr/bin/env bash
# 05-waypoint.sh: add the waypoint, then fix the L4 policy it breaks.
#
#   1. Deploy the waypoint (a Gateway of class istio-waypoint) and label the
#      namespace to use it. Both come from Flightbay's "Set up a waypoint" task.
#   2. Probe: every in-mesh caller now gets a 503. The waypoint accepted the
#      request, opened a connection to catalog, and catalog's ztunnel reset it:
#      the L4 policy from step 4 sees the waypoint's identity on that hop, not
#      checkout's.
#   3. Apply catalog-require-waypoint (Flightbay, "Block traffic that skips the
#      waypoint") and delete catalog-l4. Only the waypoint may open catalog's port.
#   4. Probe: back to 200 for everyone in the mesh. The per-caller rule now
#      has to move up to L7, which is step 6.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require kubectl

step "Deploy the waypoint and point shop at it (YAML from Flightbay)"
show kc apply -f "$LAB_ROOT/yaml/20-policies/30-waypoint.yaml"
kc -n "$NS_SHOP" wait --for=condition=Programmed "gateway/$WAYPOINT_NAME" --timeout=120s >/dev/null
kc -n "$NS_SHOP" rollout status "deploy/$WAYPOINT_NAME" --timeout=180s >/dev/null
show kc -n "$NS_SHOP" get pods -l gateway.networking.k8s.io/gateway-name="$WAYPOINT_NAME"
show kc get namespace "$NS_SHOP" --show-labels
sleep 3
show ic ztunnel-config services --service-namespace "$NS_SHOP"
log "catalog now lists a WAYPOINT. ztunnel sends every call for it there first."

step "Probe: catalog-l4 now refuses the waypoint"
"$SCRIPT_DIR/probe.sh" --no-jwt
log "503 from the waypoint. It reached catalog's pod as cluster.local/ns/shop/sa/waypoint, and"
log "catalog-l4 only allows checkout, so catalog's ztunnel reset the waypoint's connection."
log "the waypoint's access log for one of those calls:"
kc -n "$NS_SHOP" logs "deploy/$WAYPOINT_NAME" --since=2m 2>/dev/null \
  | grep ' 503 UC ' | tail -1 | cut -c1-150 | sed 's/^/    /' || true
log "    (UC = upstream connection failure: the hop after the waypoint was refused)"

step "Allow only the waypoint to reach catalog (YAML from Flightbay)"
show kc apply -f "$LAB_ROOT/yaml/20-policies/31-require-waypoint.yaml"
sleep 3
pod_ip="$(kc -n "$NS_SHOP" get pod -l app=catalog -o jsonpath='{.items[0].status.podIP}')"
direct="$(kc -n "$NS_SHOP" exec deploy/checkout -- curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${pod_ip}:8080/anything" 2>/dev/null || true)"
printf '  %-10s %-7s %-34s %s\n' checkout GET "direct to pod IP $pod_ip" "$direct  (catalog-l4 still allows checkout)"
log "ALLOW policies add up. While catalog-l4 exists, checkout can skip the waypoint."

step "Delete catalog-l4"
show kc -n "$NS_SHOP" delete authorizationpolicy catalog-l4
sleep 3
direct="$(kc -n "$NS_SHOP" exec deploy/checkout -- curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${pod_ip}:8080/anything" 2>/dev/null || true)"
printf '  %-10s %-7s %-34s %s\n' checkout GET "direct to pod IP $pod_ip" "$direct  (reset: only the waypoint may connect)"

step "Probe"
"$SCRIPT_DIR/probe.sh" --no-jwt
log "Everyone in the mesh gets 200 again, reporting included. ztunnel now only checks that the"
log "call came through the waypoint. The waypoint has no policy yet."

echo
ok "Waypoint in place. ztunnel admits only the waypoint to catalog, and the waypoint reads HTTP."
log "Next: ./scripts/06-l7-authz.sh"
