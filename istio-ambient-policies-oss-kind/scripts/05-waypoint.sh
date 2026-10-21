#!/usr/bin/env bash
# 05-waypoint.sh — the waypoint arrives, and the L4 policy has to be revised.
#
#   1. Deploy the waypoint (a Gateway of class istio-waypoint) and label the
#      namespace to use it.
#   2. Probe: every in-mesh caller now gets a 503. The waypoint accepted the
#      request, opened a connection to catalog, and catalog's ztunnel reset it:
#      the L4 policy from step 4 sees the waypoint's identity on that hop, not
#      checkout's.
#   3. Revise the L4 policy: only the waypoint may open catalog's port.
#   4. Probe: back to 200 for everyone in the mesh. The per-caller rule now
#      has to move up to L7, which is step 6.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require kubectl

step "Deploy the waypoint and attach the shop namespace to it"
show kc apply -f "$LAB_ROOT/yaml/20-policies/30-waypoint.yaml"
kc -n "$NS_SHOP" wait --for=condition=Programmed "gateway/$WAYPOINT_NAME" --timeout=120s >/dev/null
kc -n "$NS_SHOP" rollout status "deploy/$WAYPOINT_NAME" --timeout=180s >/dev/null
show kc -n "$NS_SHOP" get pods -l gateway.networking.k8s.io/gateway-name="$WAYPOINT_NAME"
show kc label namespace "$NS_SHOP" "istio.io/use-waypoint=$WAYPOINT_NAME" --overwrite
sleep 3
show ic ztunnel-config services --service-namespace "$NS_SHOP"
log "catalog now lists a WAYPOINT. ztunnel sends every call to it there first."

step "Probe: the L4 policy from step 4 now refuses the wrong hop"
"$SCRIPT_DIR/probe.sh" --no-jwt
log "503 from the waypoint. It reached catalog's pod as cluster.local/ns/shop/sa/waypoint, and"
log "catalog-l4 only allows checkout, so catalog's ztunnel reset the waypoint's connection."
log "the waypoint's access log for one of those calls:"
kc -n "$NS_SHOP" logs "deploy/$WAYPOINT_NAME" --since=2m 2>/dev/null \
  | grep ' 503 UC ' | tail -1 | cut -c1-150 | sed 's/^/    /' || true
log "    (UC = upstream connection failure: the hop after the waypoint was refused)"

step "Revise catalog-l4: the identity that connects to catalog is now the waypoint"
show kc apply -f "$LAB_ROOT/yaml/20-policies/31-l4-authz-catalog-waypoint.yaml"
sleep 3

step "Probe"
"$SCRIPT_DIR/probe.sh" --no-jwt
log "Everyone in the mesh is back to 200, reporting included. The L4 rule now says 'only via the"
log "waypoint'; who may do what is the waypoint's decision, and it has no policy yet."

echo
ok "Waypoint in place. ztunnel admits only the waypoint to catalog, and the waypoint reads HTTP."
log "Next: ./scripts/06-l7-authz.sh"
