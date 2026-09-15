#!/usr/bin/env bash
# The lab's identity provider, which is a signing key and five tokens.
#
#   ./scripts/03-identity.sh
#
# There is no Keycloak here on purpose: the lab is about routing, and all the gateway
# needs from an IdP is a JWKS to verify signatures against. One RSA key is generated per
# clone (never committed), its public half is written as identity/jwks.json, and RS256
# tokens are minted for alice, bob and carol, plus an unknown user and an alice signed by a
# different key. They land in identity/tokens.env as shell variables.
#
# Production swaps the inline JWKS for jwks.remote pointing at the real IdP. Nothing
# else on the policy changes.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -euo pipefail
ID="$HERE/identity"; mkdir -p "$ID"
ISS="${LAB_ISSUER:-https://identity.lab}"
AUD="${LAB_AUDIENCE:-model-gateway}"

echo "==> signing key"
if [ -f "$ID/signing-key.pem" ]; then echo "    already present"
else openssl genrsa -out "$ID/signing-key.pem" 2048 2>/dev/null; echo "    generated identity/signing-key.pem"; fi
# A second key that is never in the JWKS, so a token it signs is a forgery.
[ -f "$ID/wrong-key.pem" ] || openssl genrsa -out "$ID/wrong-key.pem" 2048 2>/dev/null

echo "==> JWKS"
MOD_HEX="$(openssl rsa -in "$ID/signing-key.pem" -noout -modulus 2>/dev/null | cut -d= -f2)"
MOD_HEX="$MOD_HEX" python3 - > "$ID/jwks.json" <<'PY'
import base64, json, os
n = bytes.fromhex(os.environ["MOD_HEX"])
b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()
print(json.dumps({"keys": [{"kty": "RSA", "kid": "lab-key", "use": "sig", "alg": "RS256", "n": b64(n), "e": "AQAB"}]}))
PY
echo "    identity/jwks.json (kid lab-key)"

mint() { # mint <key.pem> <json claims> -> compact JWT
  local key="$1" claims="$2"
  local b64='base64 | tr -d "\n=" | tr "/+" "_-"'
  local h p s
  h="$(printf '{"alg":"RS256","typ":"JWT","kid":"lab-key"}' | eval "$b64")"
  p="$(printf '%s' "$claims" | eval "$b64")"
  s="$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -sign "$key" -binary | eval "$b64")"
  printf '%s.%s.%s' "$h" "$p" "$s"
}
NOW=$(date +%s); EXP=$((NOW + 86400 * 30))
claims() { printf '{"iss":"%s","aud":"%s","sub":"%s","iat":%s,"exp":%s}' "$ISS" "$AUD" "$1" "$NOW" "$2"; }

echo "==> tokens (30 days, issuer $ISS, audience $AUD)"
{
  echo "export ALICE_TOKEN='$(mint "$ID/signing-key.pem" "$(claims alice $EXP)")'"
  echo "export BOB_TOKEN='$(mint "$ID/signing-key.pem" "$(claims bob $EXP)")'"
  echo "export CAROL_TOKEN='$(mint "$ID/signing-key.pem" "$(claims carol $EXP)")'"
  echo "export UNKNOWN_TOKEN='$(mint "$ID/signing-key.pem" "$(claims mallory $EXP)")'"
  echo "export BADSIG_TOKEN='$(mint "$ID/wrong-key.pem" "$(claims alice $EXP)")'"
} > "$ID/tokens.env"
chmod 600 "$ID/tokens.env" "$ID"/*.pem
. "$ID/tokens.env"
show() { printf '    %-14s sub=%-8s %s...\n' "$1" "$2" "${3:0:24}"; }
show ALICE_TOKEN alice "$ALICE_TOKEN"; show BOB_TOKEN bob "$BOB_TOKEN"; show CAROL_TOKEN carol "$CAROL_TOKEN"
show UNKNOWN_TOKEN mallory "$UNKNOWN_TOKEN"; show BADSIG_TOKEN alice "$BADSIG_TOKEN"
echo
echo "Use them in a shell with:  source identity/tokens.env"
echo "Next: ./scripts/04-opa.sh"
