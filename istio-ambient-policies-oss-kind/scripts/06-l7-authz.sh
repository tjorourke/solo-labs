#!/usr/bin/env bash
# 06-l7-authz.sh — Policy 3: an L7 AuthorizationPolicy on the waypoint.
#
# targetRefs the catalog Service, so the policy is enforced in the waypoint's
# Envoy, the one proxy in ambient that reads HTTP. checkout may GET; checkout's
# DELETE and everything from reporting come back 403.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require kubectl

step "Policy 3: AuthorizationPolicy catalog-l7 (checkout may GET, nothing else)"
show kc apply -f "$LAB_ROOT/yaml/20-policies/40-l7-authz-catalog.yaml"
sleep 3

step "Probe"
"$SCRIPT_DIR/probe.sh" --no-jwt
log "checkout GET 200. checkout DELETE 403 and reporting GET 403 are HTTP responses from the"
log "waypoint, not resets: the connection was fine, the request was not."

step "Where it was enforced: the waypoint's access log"
sleep 2
kc -n "$NS_SHOP" logs "deploy/$WAYPOINT_NAME" --since=3m 2>/dev/null \
  | grep ' 403 ' | tail -2 | cut -c1-110 | sed 's/^/    /' || true
log "    (rbac_access_denied_matched_policy[none]: no ALLOW rule matched, so the waypoint refused it)"

step "Why catalog-l4 stays: a call to the pod IP skips a service waypoint"
pod_ip="$(kc -n "$NS_SHOP" get pod -l app=catalog -o jsonpath='{.items[0].status.podIP}')"
direct="$(kc -n "$NS_SHOP" exec deploy/checkout -- curl -s -o /dev/null -w '%{http_code}' -X DELETE --max-time 5 "http://${pod_ip}:8080/anything" 2>/dev/null || true)"
printf '  %-10s %-7s %-34s %s\n' checkout DELETE "direct to pod IP $pod_ip" "$direct  (reset by ztunnel: checkout is not the waypoint)"
log "The waypoint is attached to the Service, so a call addressed to the pod IP never reaches it."
log "Only catalog-l4, admitting the waypoint alone, stops that call. Delete catalog-l4 and it is a 200."

echo
ok "Policy 3 in place: identity AND method, decided per request in the waypoint."
log "Next: ./scripts/07-jwt.sh"
