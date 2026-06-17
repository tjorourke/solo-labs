#!/usr/bin/env bash
# mint-token.sh — mint an RS256 JWT signed with the keypair that 04-routing.sh
# generated, so the inline JWKS on the gateway validates it. The `version`
# claim is what entJWT.claimsToHeaders projects into x-target-version.
#
# Usage:
#   ./scripts/mint-token.sh [version] [tenant]
#   ./scripts/mint-token.sh v2            # version claim = v2
#   ./scripts/mint-token.sh latest acme   # version=latest, tenant=acme
#
# Prints the token to stdout. Example:
#   TOKEN=$(./scripts/mint-token.sh v2)
#   curl -H "Authorization: Bearer $TOKEN" http://localhost:8080/

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GEN="$LAB_ROOT/.gen"
KEY="$GEN/jwt-private.pem"

[[ -f "$KEY" ]] || { echo "ERROR: $KEY not found — run ./scripts/04-routing.sh first" >&2; exit 1; }

VERSION="${1:-v2}"
TENANT="${2:-}"
KID="$(cat "$GEN/kid.txt" 2>/dev/null || echo versioned-routing-key)"

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

now=$(date +%s)
exp=$((now + 3600))

header="{\"alg\":\"RS256\",\"typ\":\"JWT\",\"kid\":\"${KID}\"}"
if [[ -n "$TENANT" ]]; then
  payload="{\"iss\":\"versioned-routing-lab\",\"aud\":\"public-api\",\"tenant\":\"${TENANT}\",\"version\":\"${VERSION}\",\"iat\":${now},\"exp\":${exp}}"
else
  payload="{\"iss\":\"versioned-routing-lab\",\"aud\":\"public-api\",\"version\":\"${VERSION}\",\"iat\":${now},\"exp\":${exp}}"
fi

h_b64=$(printf '%s' "$header"  | b64url)
p_b64=$(printf '%s' "$payload" | b64url)
signing_input="${h_b64}.${p_b64}"
sig=$(printf '%s' "$signing_input" | openssl dgst -sha256 -sign "$KEY" -binary | b64url)

printf '%s.%s\n' "$signing_input" "$sig"
