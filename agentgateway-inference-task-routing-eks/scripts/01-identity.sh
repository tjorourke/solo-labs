#!/usr/bin/env bash
# The lab's identity provider: a signing key and four tokens.
#
#   ./scripts/01-identity.sh
#
# Three employees and one forgery. bob may use private models and the approved frontier,
# alice private only, dave the frontier only; what each may use is in opa/routing-data.json,
# not in the token. The token carries who they are, nothing about where they may go.
#
# There is no Keycloak here on purpose: the lab is about routing, and all the gateway needs
# from an identity provider is a JWKS to verify signatures against. Part 3's signing key is
# reused when it is next door, so both parts' tokens verify against the same JWKS.
# Production swaps jwks.inline for jwks.remote pointing at the real IdP.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -euo pipefail
ID="$HERE/identity"; mkdir -p "$ID"
PART3_ID="$(cd "${PART3_DIR:-$HERE/../agentgateway-inference-identity-routing-eks}" 2>/dev/null && pwd || true)/identity"
ISS="${LAB_ISSUER:-https://identity.lab}"
AUD="${LAB_AUDIENCE:-model-gateway}"

echo "==> signing key"
if [ -f "$ID/signing-key.pem" ]; then echo "    already present"
elif [ -f "$PART3_ID/signing-key.pem" ]; then cp "$PART3_ID/signing-key.pem" "$ID/"; [ -f "$PART3_ID/wrong-key.pem" ] && cp "$PART3_ID/wrong-key.pem" "$ID/"; echo "    reused Part 3's identity/signing-key.pem"
else openssl genrsa -out "$ID/signing-key.pem" 2048 2>/dev/null; echo "    generated identity/signing-key.pem"; fi
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
  echo "export BOB_TOKEN='$(mint "$ID/signing-key.pem" "$(claims bob $EXP)")'"
  echo "export ALICE_TOKEN='$(mint "$ID/signing-key.pem" "$(claims alice $EXP)")'"
  echo "export DAVE_TOKEN='$(mint "$ID/signing-key.pem" "$(claims dave $EXP)")'"
  # The caller whose organisation classifies its own data. Same key, same issuer: the
  # difference is in the entitlements, not the token, which is the point the token makes.
  echo "export MARTINK_TOKEN='$(mint "$ID/signing-key.pem" "$(claims martink $EXP)")'"
  echo "export BADSIG_TOKEN='$(mint "$ID/wrong-key.pem" "$(claims bob $EXP)")'"
} > "$ID/tokens.env"
chmod 600 "$ID/tokens.env" "$ID"/*.pem
. "$ID/tokens.env"
show() { printf '    %-13s sub=%-7s %s...\n' "$1" "$2" "${3:0:24}"; }
show BOB_TOKEN bob "$BOB_TOKEN"; show ALICE_TOKEN alice "$ALICE_TOKEN"; show DAVE_TOKEN dave "$DAVE_TOKEN"
show MARTINK_TOKEN martink "$MARTINK_TOKEN"; show BADSIG_TOKEN bob "$BADSIG_TOKEN"
echo
echo "Use them in a shell with:  source identity/tokens.env"
echo "Next: ./scripts/02-router.sh"
