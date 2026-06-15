#!/usr/bin/env bash
# mint-token.sh [user] — mint a Keycloak access token for a realm user (default
# alice, password = username) and print its decoded payload. This is the INBOUND
# token: sub=<user>, groups=[...], iss=keycloak, aud=kagent — and crucially NO
# `act` claim. Compare with the exchanged OBO token shown by ask.sh.
#
# Prints the raw token on the last line (so other scripts can capture it).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

USER="${1:-alice}"; PASS="${2:-$USER}"

kc -n "$KEYCLOAK_NS" port-forward svc/keycloak 18080:80 >/tmp/kc-pf.$$ 2>&1 &
PF=$!; trap 'kill $PF 2>/dev/null' EXIT
for _ in $(seq 1 30); do curl -s -o /dev/null "http://localhost:18080/realms/${KEYCLOAK_REALM}/.well-known/openid-configuration" && break; sleep 1; done

TOKEN="$(curl -s -X POST "http://localhost:18080/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d "grant_type=password&client_id=${KEYCLOAK_CLIENT}&username=${USER}&password=${PASS}" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin).get("access_token",""))')"
[[ -n "$TOKEN" ]] || die "failed to mint token for ${USER} (is Keycloak up? realm ${KEYCLOAK_REALM}?)"

step "Inbound Keycloak token for '${USER}' (decoded)"
decode_jwt "$TOKEN" >&2
printf '%s\n' "$TOKEN"
