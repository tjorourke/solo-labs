#!/usr/bin/env bash
# mint-token.sh — mint an RS256 JWT signed with the key 07-jwt-teams.sh generated,
# so the gateway's inline JWKS validates it. The `team` claim selects the team's
# Bedrock backend (and its application inference profile) at the gateway. The
# client never holds an ARN — only its own token.
#
# Usage:
#   ./scripts/mint-token.sh [team]
#   TOKEN=$(./scripts/mint-token.sh finance)
#   curl -H "Authorization: Bearer $TOKEN" -H "x-team: finance" localhost:8080/v1/chat/completions ...
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
GEN="$(cd "$SCRIPT_DIR/.." && pwd)/.gen"
KEY="$GEN/jwt-private.pem"
[[ -f "$KEY" ]] || { echo "ERROR: $KEY not found — run ./scripts/07-jwt-teams.sh first" >&2; exit 1; }

TEAM="${1:-finance}"
KID="$(cat "$GEN/kid.txt" 2>/dev/null || echo "$JWT_KID")"
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
now=$(date +%s); exp=$((now + 3600))
header="{\"alg\":\"RS256\",\"typ\":\"JWT\",\"kid\":\"${KID}\"}"
payload="{\"iss\":\"${JWT_ISSUER}\",\"aud\":\"${JWT_AUDIENCE}\",\"team\":\"${TEAM}\",\"iat\":${now},\"exp\":${exp}}"
h_b64=$(printf '%s' "$header"  | b64url)
p_b64=$(printf '%s' "$payload" | b64url)
sig=$(printf '%s' "${h_b64}.${p_b64}" | openssl dgst -sha256 -sign "$KEY" -binary | b64url)
printf '%s.%s.%s\n' "$h_b64" "$p_b64" "$sig"
