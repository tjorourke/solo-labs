#!/usr/bin/env bash
# mint-token.sh — mint an RS256 JWT signed with the key 04-rbac.sh generated, so
# the inline JWKS on the gateway validates it. Claims carry the identity the
# authorization CEL checks (org, team) plus an `llms` model-entitlement claim
# that travels with the request and shows up in the access log.
#
# Usage:
#   ./scripts/mint-token.sh [team] [org]
#   ./scripts/mint-token.sh data-platform        # authorized team (default)
#   ./scripts/mint-token.sh marketing            # wrong team -> 403
#
#   TOKEN=$(./scripts/mint-token.sh)
#   curl -H "Authorization: Bearer $TOKEN" http://localhost:8080/v1/messages ...

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GEN="$LAB_ROOT/.gen"
KEY="$GEN/jwt-private.pem"

[[ -f "$KEY" ]] || { echo "ERROR: $KEY not found — run ./scripts/04-rbac.sh first" >&2; exit 1; }

TEAM="${1:-data-platform}"
ORG="${2:-acme}"
KID="$(cat "$GEN/kid.txt" 2>/dev/null || echo claude-code-key)"

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

now=$(date +%s)
exp=$((now + 3600))

header="{\"alg\":\"RS256\",\"typ\":\"JWT\",\"kid\":\"${KID}\"}"
payload="{\"iss\":\"claude-code-lab\",\"aud\":\"anthropic-api\",\"org\":\"${ORG}\",\"team\":\"${TEAM}\",\"llms\":{\"openai\":[\"gpt-4o-mini\"]},\"iat\":${now},\"exp\":${exp}}"

h_b64=$(printf '%s' "$header"  | b64url)
p_b64=$(printf '%s' "$payload" | b64url)
signing_input="${h_b64}.${p_b64}"
sig=$(printf '%s' "$signing_input" | openssl dgst -sha256 -sign "$KEY" -binary | b64url)

printf '%s.%s\n' "$signing_input" "$sig"
