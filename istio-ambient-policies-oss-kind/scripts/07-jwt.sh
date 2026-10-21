#!/usr/bin/env bash
# 07-jwt.sh — Policy 4: JWT validation plus a token-gated DELETE.
#
#   1. RequestAuthentication on the catalog Service: trust issuer
#      testing@secure.istio.io, verify with the inlined key.
#   2. Replace catalog-l7: GET for checkout as before, DELETE for checkout
#      only with a verified token from that issuer.
#   3. Probe with no token, a bad token and the signed token.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require kubectl

step "Policy 4: RequestAuthentication catalog-jwt, then catalog-l7 with the DELETE rule"
show kc apply -f "$LAB_ROOT/yaml/20-policies/50-jwt-requestauth.yaml"
show kc apply -f "$LAB_ROOT/yaml/20-policies/51-l7-authz-catalog-jwt.yaml"
sleep 3

step "Probe"
"$SCRIPT_DIR/probe.sh"
log "checkout DELETE without a token: 403. With the signed token: 200."

step "Two more cases"
bad="$(curl_code "$NS_SHOP" checkout DELETE -H 'Authorization: Bearer not.a.token')"
printf '  %-10s %-7s %-30s %s\n' checkout DELETE "malformed token" "$bad  (401: the RequestAuthentication rejected it)"
rep="$(curl_code "$NS_SHOP" reporting DELETE -H "Authorization: Bearer $(cat "$LAB_ROOT/jwt/demo.jwt")")"
printf '  %-10s %-7s %-30s %s\n' reporting DELETE "valid token, wrong identity" "$rep  (403: the token is fine, the workload is not)"
echo
log "The token claims the waypoint matched on:"
cut -d. -f2 "$LAB_ROOT/jwt/demo.jwt" | tr '_-' '/+' | base64 -d 2>/dev/null | sed 's/^/    /'; echo

echo
ok "Policy 4 in place: a DELETE needs a workload identity AND an end-user token, and both are checked in the waypoint."
log "Done. Teardown: ./scripts/99-teardown.sh"
