#!/usr/bin/env bash
# 06-jwt.sh: Policy 4, JWT validation plus a token-gated POST.
#
#   1. Flightbay's "Require a JWT" output: a RequestAuthentication on the
#      ratings Service (issuer testing@secure.istio.io, inline key) and an
#      ALLOW for POST with a valid token.
#   2. Probe with no token, a bad token and the signed token. demo-client can
#      POST with the token too, because that rule does not name a caller.
#   3. Hand-written fix: the same rule with the reviews identity added.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require kubectl
body=(-H 'Content-Type: application/json' -d '{"reviewerId":"probe","productId":0,"rating":4}')
tok="Authorization: Bearer $(cat "$LAB_ROOT/jwt/demo.jwt")"

step "Policy 4: RequestAuthentication ratings-jwt and a POST rule (YAML from Flightbay)"
show kc apply -f "$LAB_ROOT/yaml/20-policies/50-jwt.yaml"
wait_code 200 "$NS_APP" reviews-v2 POST "${body[@]}" -H "$tok"

step "Probe"
"$SCRIPT_DIR/probe.sh"
log "reviews-v2 POST without a token: 403. With the signed token: 200."
bad="$(curl_code "$NS_APP" reviews-v2 POST "${body[@]}" -H 'Authorization: Bearer not.a.token')"
printf '  %-12s %-6s %-30s %s\n' reviews-v2 POST "malformed token" "$bad  (401: the RequestAuthentication rejected it)"
dc="$(curl_code "$NS_APP" demo-client POST "${body[@]}" -H "$tok")"
printf '  %-12s %-6s %-30s %s\n' demo-client POST "valid token" "$dc  (200: Flightbay's rule checks the token, not the caller)"

step "Tighten it: POST needs the token AND the reviews identity (hand-written)"
show kc apply -f "$LAB_ROOT/yaml/20-policies/52-jwt-allow-reviews-only.yaml"
wait_code 403 "$NS_APP" demo-client POST "${body[@]}" -H "$tok"
dc="$(curl_code "$NS_APP" demo-client POST "${body[@]}" -H "$tok")"
printf '  %-12s %-6s %-30s %s\n' demo-client POST "valid token, wrong identity" "$dc  (403: the token is fine, the workload is not)"
"$SCRIPT_DIR/probe.sh"

echo
ok "Policy 4 in place: a POST needs a workload identity AND an end-user token, both checked in the waypoint."
log "Done. Teardown: ./scripts/99-teardown.sh"
