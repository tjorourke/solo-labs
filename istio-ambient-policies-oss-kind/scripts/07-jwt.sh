#!/usr/bin/env bash
# 07-jwt.sh: Policy 4, JWT validation plus a token-gated DELETE.
#
#   1. Flightbay's "Require a JWT" output: a RequestAuthentication on the
#      catalog Service (issuer testing@secure.istio.io, inline key) and an
#      ALLOW for DELETE with a valid token.
#   2. Probe with no token, a bad token and the signed token. reporting can
#      DELETE with the token too, because that rule does not name a caller.
#   3. Hand-written fix: the same rule with checkout's identity added.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require kubectl

step "Policy 4: RequestAuthentication catalog-jwt and a DELETE rule (YAML from Flightbay)"
show kc apply -f "$LAB_ROOT/yaml/20-policies/50-jwt.yaml"
sleep 3

step "Probe"
"$SCRIPT_DIR/probe.sh"
log "checkout DELETE without a token: 403. With the signed token: 200."
bad="$(curl_code "$NS_SHOP" checkout DELETE -H 'Authorization: Bearer not.a.token')"
printf '  %-10s %-7s %-30s %s\n' checkout DELETE "malformed token" "$bad  (401: the RequestAuthentication rejected it)"
rep="$(curl_code "$NS_SHOP" reporting DELETE -H "Authorization: Bearer $(cat "$LAB_ROOT/jwt/demo.jwt")")"
printf '  %-10s %-7s %-30s %s\n' reporting DELETE "valid token" "$rep  (200: Flightbay's rule checks the token, not the caller)"

step "Tighten it: DELETE needs the token AND the checkout identity (hand-written)"
show kc apply -f "$LAB_ROOT/yaml/20-policies/52-jwt-allow-checkout-only.yaml"
sleep 3
rep="$(curl_code "$NS_SHOP" reporting DELETE -H "Authorization: Bearer $(cat "$LAB_ROOT/jwt/demo.jwt")")"
printf '  %-10s %-7s %-30s %s\n' reporting DELETE "valid token, wrong identity" "$rep  (403: the token is fine, the workload is not)"
"$SCRIPT_DIR/probe.sh"

echo
log "The token claims the waypoint matched on:"
cut -d. -f2 "$LAB_ROOT/jwt/demo.jwt" | tr '_-' '/+' | base64 -d 2>/dev/null | sed 's/^/    /'; echo

echo
ok "Policy 4 in place: a DELETE needs a workload identity AND an end-user token, and both are checked in the waypoint."
log "Done. Teardown: ./scripts/99-teardown.sh"
