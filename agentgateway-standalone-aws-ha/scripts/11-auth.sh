#!/bin/bash
# Cognito JWT authentication and CEL authorization.
#
# Every refusal below is the gateway rejecting a real, correctly signed token that
# simply does not carry the right claim. Nothing is hand-edited.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_tools; require_aws; require_stack

ISSUER="$(tf_out cognito_issuer)"
AUDIENCE="$(tf_out cognito_api_audience)"
TOKEN_URL="$(tf_out cognito_token_url)"

hdr "1. The issuer"
log "issuer:    $ISSUER"
log "JWKS:      $ISSUER/.well-known/jwks.json"
log "token URL: $TOKEN_URL"
log "resource server (scope prefix): $AUDIENCE"
echo
log "The gateway fetches and caches that JWKS. Keys the pool publishes:"
curl -s "$ISSUER/.well-known/jwks.json" | jq -r '.keys[] | "    kid=\(.kid) alg=\(.alg) use=\(.use)"'

hdr "2. Mint a token, for real"
cat <<EOT
  This is the whole command, so any refusal below can be reproduced:

    curl -s -u "\$CLIENT_ID:\$CLIENT_SECRET" \\
      -d 'grant_type=client_credentials' \\
      --data-urlencode 'scope=$AUDIENCE/llm.invoke' \\
      $TOKEN_URL | jq -r .access_token

EOT
FULL="$(mint_token all)"
LLM_ONLY="$(mint_token llm-only)"

log "The full-scope token's claims:"
jwt_payload "$FULL" | sed 's/^/    /'
echo
log "Note there is no aud claim. Cognito access tokens carry client_id and scope"
log "instead, which is why the jwtAuth policy configures issuer and JWKS only:"
log "audiences are optional, and requiring one here would reject every valid token."

hdr "3. No token, bad token"
expect "no credential"      401 "$(code "$GATEWAY_URL/api/private/headers")"
expect "malformed token"    401 "$(code -H 'authorization: Bearer not.a.real.jwt' "$GATEWAY_URL/api/private/headers")"
expect "token from the wrong issuer" 401 \
  "$(code -H 'authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJodHRwczovL2V2aWwuZXhhbXBsZSIsInN1YiI6ImF0dGFja2VyIiwiZXhwIjo0MDcwOTA4ODAwfQ.invalid' "$GATEWAY_URL/api/private/headers")"

hdr "4. Authorization on the scope claim"
log "The route allows a caller holding $AUDIENCE/llm.invoke."
expect "token with llm.invoke"  200 "$(code -H "authorization: Bearer $LLM_ONLY" "$GATEWAY_URL/api/private/headers")"
NOSCOPE="$(mint_token all "$AUDIENCE/mcp.call")"
log "A token holding only mcp.call is authenticated but not authorized here:"
expect "token with only mcp.call" 403 "$(code -H "authorization: Bearer $NOSCOPE" "$GATEWAY_URL/api/private/headers")"
log "401 versus 403 is the distinction worth pointing at: the second token is"
log "perfectly valid, it just is not allowed to do this."

hdr "5. The gateway tells the upstream who the caller is"
log "The client sends x-verified-subject: attacker. The transformation policy sets"
log "that header from the verified token, so the client's value is overwritten."
curl -s -H "authorization: Bearer $LLM_ONLY" \
     -H 'x-verified-subject: attacker' \
     -H 'x-verified-scope: admin' \
     "$GATEWAY_URL/api/private/headers" \
  | jq '.headers | with_entries(select(.key | startswith("x-verified")))'
subj="$(curl -s -H "authorization: Bearer $LLM_ONLY" -H 'x-verified-subject: attacker' \
  "$GATEWAY_URL/api/private/headers" | jq -r '.headers["x-verified-subject"]')"
expect "the upstream sees the verified subject, not the client's claim" \
  "$(jwt_payload "$LLM_ONLY" | jq -r .sub)" "$subj"

hdr "6. Human identity: group membership"
cat <<EOT
  The seeded user is in the platform group, and the same route allows
  "platform" in jwt["cognito:groups"].

  Note the guard on that expression in config.yaml. A machine token has scope and
  no cognito:groups; a human token is the other way round. An unguarded reference
  to a claim the token does not carry makes the expression fail rather than
  evaluate to false, and a failed allow rule is a refusal. has() only accepts a
  field selection, so a claim name containing a colon has to be guarded with map
  membership instead: "cognito:groups" in jwt.

  Sign in at $GATEWAY_URL/ui as:
    user     $(tf_out cognito_test_user)
    password (cd terraform && $TF output -raw cognito_test_user_password)

  The viewer group exists so you can add a user to it and watch the admin UI
  authorization rule refuse a perfectly valid login.
EOT

summary
