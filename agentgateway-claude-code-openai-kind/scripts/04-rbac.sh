#!/usr/bin/env bash
# 04-rbac.sh — generate an RS256 keypair, derive the public JWKS, render it into
# the EnterpriseAgentgatewayPolicy, and apply it. The policy requires a valid
# JWT (Strict) and authorizes only org=acme / team=data-platform via CEL.
# The private key stays in .gen/ (git-ignored); mint-token.sh signs with it.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require openssl
require xxd

GEN="$LAB_ROOT/.gen"
mkdir -p "$GEN"
KEY="$GEN/jwt-private.pem"

step "Generating the RS256 signing key + JWKS"
if [[ -f "$KEY" ]]; then
  log "reusing existing key $KEY"
else
  openssl genrsa -out "$KEY" 2048 2>/dev/null
  ok "wrote $KEY"
fi
printf '%s' "$JWT_KID" > "$GEN/kid.txt"

MOD_HEX="$(openssl rsa -in "$KEY" -noout -modulus | sed 's/^Modulus=//')"
N_B64URL="$(printf '%s' "$MOD_HEX" | xxd -r -p | openssl base64 -A | tr '+/' '-_' | tr -d '=')"
JWKS_JSON="{\"keys\":[{\"kty\":\"RSA\",\"use\":\"sig\",\"alg\":\"RS256\",\"kid\":\"${JWT_KID}\",\"n\":\"${N_B64URL}\",\"e\":\"AQAB\"}]}"
printf '%s' "$JWKS_JSON" > "$GEN/jwks.json"
ok "JWKS derived (kid=$JWT_KID)"

step "Rendering and applying the EnterpriseAgentgatewayPolicy"
# The inline JWKS is indented to sit under 'inline: |' (14 spaces in the template).
JWKS_INDENTED="$(printf '%s' "$JWKS_JSON" | sed 's/^/              /')"
awk -v repl="$JWKS_INDENTED" '
  /^[[:space:]]*__JWKS_JSON__[[:space:]]*$/ { print repl; next }
  { print }
' "$LAB_ROOT/yaml/rbac-policy.yaml" > "$GEN/rbac-policy.yaml"
kctx apply -f "$GEN/rbac-policy.yaml" >/dev/null
ok "policy 'claude-code-rbac' applied (JWT Strict + org/team authorization)"

echo "  Next: ./scripts/demo.sh   (port-forward), then ./scripts/test.sh" >&2
