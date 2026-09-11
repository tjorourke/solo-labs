#!/bin/bash
# The STS, three ways: impersonation, delegation, dual authentication.
#
# One mechanism. What changes is what the client sends and what the downstream
# service ends up seeing, and the only way to show that honestly is to read the
# credential the upstream actually received rather than describe it.
#
# The echo service is what makes that possible: it returns the headers it was
# called with, so every claim below is decoded from a real request.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_tools; require_aws; require_stack

AUDIENCE="$(tf_out cognito_api_audience)"
STS_ISSUER="$GATEWAY_URL/sts"

# The exchanged target runs the echo tools through backendAuth.oauthTokenExchange,
# so its headers tool reports what the gateway sent upstream.
upstream_auth() { # upstream_auth <token> [extra-header...] -> the bearer the upstream saw
  local tok="$1"; shift
  local sid; sid="$(mcp_init "$tok")"
  mcp_rpc "$tok" "$sid" \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"exchanged_headers","arguments":{}}}' \
    | jq -r '.result.content[0].text // "{}"' \
    | jq -r '.headers.authorization // empty' | sed 's/^[Bb]earer //'
}

hdr "0. The STS is running on every node"
for id in $(fleet_instances); do
  h="$(node_try "$id" "curl -sf -m 3 http://127.0.0.1:7777/healthz && echo ok" | tr -d '\n ')"
  m="$(node_try "$id" "systemctl is-active agentgateway-sts" | tr -d '\n ')"
  printf '  %-20s systemd=%-8s health=%s\n' "$id" "${m:-?}" "${h:-unreachable}"
done
log "It is a second process on the same box, on loopback, reading its own section"
log "of the same config file the proxy reads."

# ---------------------------------------------------------------------------
hdr "1. Impersonation: the gateway swaps the user's token for its own"
# ---------------------------------------------------------------------------
cat <<'EOT'
  The client sends the token Cognito gave it. The gateway exchanges that at the
  STS for a token it signs itself, and sends the new one upstream. The user is
  still the subject; what changes is who vouches for the claim.
EOT
USER_TOK="$(mint_token all)"
log "the token the client presented:"
jwt_payload "$USER_TOK" | jq '{iss, sub, scope}' | sed 's/^/    /'

UP="$(upstream_auth "$USER_TOK")"
[[ -n "$UP" ]] || die "the upstream saw no authorization header; is the STS healthy?"
log "the token the upstream received:"
jwt_payload "$UP" | jq '{iss, sub, aud, act}' | sed 's/^/    /'

expect_contains "the upstream token is issued by the STS, not by Cognito" "$STS_ISSUER" "$(jwt_payload "$UP" | jq -r .iss)"
expect_contains "and it still names the same user" "$(jwt_payload "$USER_TOK" | jq -r .sub)" "$(jwt_payload "$UP" | jq -r .sub)"
log "The MCP server never saw the user's Cognito token. It cannot replay it, and"
log "a leak there is not a leak of the user's IdP credential."

# ---------------------------------------------------------------------------
hdr "2. Delegation: the token names the user AND the agent"
# ---------------------------------------------------------------------------
cat <<'EOT'
  Impersonation answers "who is this for". Delegation answers "who is doing it",
  which is the question an audit asks after the fact. The client sends its own
  machine token as the actor alongside the user's token, and the STS puts both
  identities in one credential: sub is the user, act.sub is the agent.
EOT
AGENT_TOK="$(mint_token llm-only)"
log "the agent's own token:"
jwt_payload "$AGENT_TOK" | jq '{iss, sub, scope}' | sed 's/^/    /'

# The exchange is a direct call to the STS here, because the gateway's route
# policy is what decides whether to pass an actor token, and this shows the
# mechanism rather than the routing.
NODE="$(fleet_instances | head -1)"
DELEGATED="$(node_try "$NODE" "curl -s -m 10 http://127.0.0.1:7777/token \
  -d grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
  -d subject_token_type=urn:ietf:params:oauth:token-type:jwt \
  -d requested_token_type=urn:ietf:params:oauth:token-type:jwt \
  -d audience=internal-tools \
  --data-urlencode subject_token=$USER_TOK \
  -d actor_token_type=urn:ietf:params:oauth:token-type:jwt \
  --data-urlencode actor_token=$AGENT_TOK" | jq -r '.access_token // empty')"

if [[ -n "$DELEGATED" ]]; then
  log "the delegated token:"
  jwt_payload "$DELEGATED" | jq '{iss, sub, aud, act}' | sed 's/^/    /'
  expect_contains "sub is still the user" "$(jwt_payload "$USER_TOK" | jq -r .sub)" "$(jwt_payload "$DELEGATED" | jq -r .sub)"
  expect "act.sub names the agent" "$(jwt_payload "$AGENT_TOK" | jq -r .sub)" "$(jwt_payload "$DELEGATED" | jq -r '.act.sub // "none"')"
  log "One credential, two identities, and a downstream service that logs the"
  log "token logs both without being taught anything new."
else
  warn "the STS returned no delegated token; check /var/log/agentgateway/sts.log on $NODE"
  FAIL=$((FAIL+1))
fi

# ---------------------------------------------------------------------------
hdr "3. Dual authentication: two independent credentials on one route"
# ---------------------------------------------------------------------------
cat <<'EOT'
  Leg 1 is the MCP client proving who it is to the gateway, which is the
  mcpAuthentication policy on the listener. Leg 2 is the gateway proving to the
  backend, which is the exchange above. Neither credential is the other one, and
  the request needs both.
EOT
log "leg 1, no token at all:"
expect "MCP without a credential is refused" 401 "$(code -X POST "$GATEWAY_URL/mcp" -H 'content-type: application/json' -d '{}')"
curl -s -D - -o /dev/null -X POST "$GATEWAY_URL/mcp" -H 'content-type: application/json' -d '{}' \
  | grep -i 'www-authenticate' | sed 's/^/    /'

log "leg 2, with a valid client credential, the bearer that reaches the backend is"
log "a different token entirely:"
printf '    client presented : %s…\n' "$(echo "$USER_TOK" | cut -c1-24)"
printf '    backend received : %s…\n' "$(echo "$UP" | cut -c1-24)"
[[ "$USER_TOK" != "$UP" ]] && ok "the two legs carry different credentials" || { warn "the backend saw the client's own token"; FAIL=$((FAIL+1)); }

cat <<'EOT'

  Worth knowing before you design around this: the STS mints, it does not store.
  Nothing above is stateful, which is why every node runs its own copy and why
  the fleet needs no shared session for any of it. The one piece of shared state
  is the signing key, so a downstream validator can fetch one JWKS and accept a
  token from any of the three nodes.
EOT

summary
