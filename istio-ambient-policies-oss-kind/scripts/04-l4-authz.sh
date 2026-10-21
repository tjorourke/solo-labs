#!/usr/bin/env bash
# 04-l4-authz.sh: Policy 2, identity-based L4 authorization on ratings.
#
#   1. ratings-l4 (hand-written): a selector-based ALLOW for the reviews
#      identity only. ztunnel on the ratings node enforces it.
#   2. Probe: every in-mesh caller gets 503. Flightbay put a waypoint in front
#      of ratings, so the connection ztunnel checks comes from the waypoint's
#      identity, not from reviews.
#   3. ratings-require-waypoint (Flightbay, "Block traffic that skips the
#      waypoint"), then delete ratings-l4. Only the waypoint may open the port.
#   4. Probe: back to 200 in the mesh. The per-caller rule moves to L7 (step 5).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require kubectl

step "Policy 2: AuthorizationPolicy ratings-l4 (ALLOW only bookinfo-reviews, hand-written)"
show kc apply -f "$LAB_ROOT/yaml/20-policies/20-l4-authz-ratings.yaml"
# ztunnel checks an L4 policy when a connection opens. The waypoint reuses its
# open connections to the ratings pod, so while traffic keeps them busy they go
# on returning 200. Restart the waypoint so every request needs a new one.
show kc -n "$NS_APP" rollout restart "deploy/$WAYPOINT_NAME"
kc -n "$NS_APP" rollout status "deploy/$WAYPOINT_NAME" --timeout=120s >/dev/null
wait_code 503 "$NS_APP" reviews-v2 GET

step "Probe: ratings-l4 refuses the waypoint"
"$SCRIPT_DIR/probe.sh" --no-jwt
log "503 from the waypoint. It reached the ratings pod as cluster.local/ns/$NS_APP/sa/$WAYPOINT_NAME,"
log "and ratings-l4 only allows bookinfo-reviews, so ratings' ztunnel reset the waypoint's connection."

step "Allow only the waypoint to reach ratings (YAML from Flightbay)"
show kc apply -f "$LAB_ROOT/yaml/20-policies/31-require-waypoint.yaml"
sleep 5
pod_ip="$(kc -n "$NS_APP" get pod -l app=ratings -o jsonpath='{.items[0].status.podIP}')"
direct() { kc -n "$NS_APP" exec deploy/reviews-v2 -- curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${pod_ip}:9080/ratings/0" 2>/dev/null || true; }
printf '  %-12s %-6s %-30s %s\n' reviews-v2 GET "direct to pod IP $pod_ip" "$(direct)  (ratings-l4 still allows reviews)"
log "ALLOW policies add up. While ratings-l4 exists, reviews can skip the waypoint."

step "Delete ratings-l4"
show kc -n "$NS_APP" delete authorizationpolicy ratings-l4
wait_code 200 "$NS_APP" reviews-v2 GET; sleep 3
printf '  %-12s %-6s %-30s %s\n' reviews-v2 GET "direct to pod IP $pod_ip" "$(direct)  (reset: only the waypoint may connect)"

step "Probe"
"$SCRIPT_DIR/probe.sh" --no-jwt
log "Everyone in the mesh gets 200 again. ztunnel now only checks that the call came"
log "through the waypoint. The waypoint has no policy yet."

echo
ok "Policy 2 in place: ztunnel admits only the waypoint to ratings."
log "Next: ./scripts/05-l7-authz.sh"
