#!/bin/bash
# MCP: two targets multiplexed, OAuth on both issuers, per-tool authorization.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_tools; require_aws; require_stack

AUDIENCE="$(tf_out cognito_api_audience)"

# --- minimal MCP client over streamable HTTP -------------------------------
mcp_init() { # mcp_init <token> -> prints the session id
  local tok="$1" hdrs
  hdrs="$(mktemp)"
  curl -s -D "$hdrs" -X POST "$GATEWAY_URL/mcp" \
    -H "authorization: Bearer $tok" -H 'content-type: application/json' \
    -H 'accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"lab","version":"1"}}}' >/dev/null
  grep -i '^mcp-session-id' "$hdrs" | sed 's/.*: //' | tr -d '\r\n'
  rm -f "$hdrs"
}

mcp_rpc() { # mcp_rpc <token> <session> <json-body> [base-url]
  local tok="$1" sid="$2" body="$3" base="${4:-$GATEWAY_URL}"
  curl -s -X POST "$base/mcp" \
    -H "authorization: Bearer $tok" -H "mcp-session-id: $sid" \
    -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' \
    -d "$body" | sed -n 's/^data: //p' | head -1
}

tool_names() { # tool_names <token>
  local tok="$1" sid; sid="$(mcp_init "$tok")"
  mcp_rpc "$tok" "$sid" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
    | jq -r '[.result.tools[]?.name] | sort | join(",")'
}

hdr "1. Unauthenticated MCP is refused, and says where to go"
expect "POST /mcp without a token" 401 "$(code -X POST "$GATEWAY_URL/mcp" -H 'content-type: application/json' -d '{}')"
log "The 401 carries the resource metadata pointer an MCP client uses to discover"
log "the authorization server:"
curl -s -D - -o /dev/null -X POST "$GATEWAY_URL/mcp" -H 'content-type: application/json' -d '{}' \
  | grep -i 'www-authenticate' | sed 's/^/    /'
echo
log "Protected resource metadata:"
curl -s "$GATEWAY_URL/.well-known/oauth-protected-resource/mcp" | jq . | sed 's/^/    /'

hdr "2. Two targets, one tool list"
log "The gateway federates a hosted MCP server and a REST API described by OpenAPI"
log "into a single virtual MCP server. prefixMode: always namespaces the names."
FULL="$(mint_token all)"
SID="$(mcp_init "$FULL")"
mcp_rpc "$FULL" "$SID" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | jq -r '.result.tools[] | "    \(.name)  -  \(.description // "" | .[0:70])"'
echo
log "The echo_* tools are not served by an MCP server at all. agentgateway generated"
log "them from config/echo-openapi.json and calls the REST API directly."

hdr "3. Calling a tool"
log "echo_whoami reaches the node-local echo service, so the result names the node:"
mcp_rpc "$FULL" "$SID" '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo_whoami","arguments":{}}}' \
  | jq -r '.result.content[0].text // (.error|tostring)' | head -c 400 | sed 's/^/    /'
echo; echo
log "bin_count-characters reaches the hosted MCP server:"
mcp_rpc "$FULL" "$SID" '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"bin_count-characters","arguments":{"text":"agentgateway","character":"a"}}}' \
  | jq -r '.result.content[0].text // (.error|tostring)' | sed 's/^/    /'

hdr "4. Per-tool authorization, on the caller's identity"
cat <<EOT
  The rules in config.yaml are:
    echo target  needs $AUDIENCE/mcp.call
    bin target   needs $AUDIENCE/admin
    or           membership of the platform group

  These filter tools/list as well as gating tools/call, so a caller only ever sees
  the tools it is allowed to use. That matters: an agent cannot be tempted by a
  tool it was never shown.
EOT
echo
MCP_ONLY="$(mint_token all "$AUDIENCE/mcp.call")"
LLM_ONLY="$(mint_token llm-only)"
printf '  %-34s %s\n' "all three scopes:"  "$(tool_names "$FULL")"
printf '  %-34s %s\n' "mcp.call only:"     "$(tool_names "$MCP_ONLY")"
printf '  %-34s %s\n' "llm.invoke only:"   "$(tool_names "$LLM_ONLY")"
echo
expect "mcp.call sees the echo tools" "echo_headers,echo_status,echo_whoami" "$(tool_names "$MCP_ONLY")"
expect "llm.invoke sees no tools"     ""                                    "$(tool_names "$LLM_ONLY")"

log ""
log "And a call to a tool the caller cannot see is refused, not just hidden:"
SID2="$(mcp_init "$MCP_ONLY")"

# A refused tool call comes back as an HTTP error, not a JSON-RPC error body, so
# check the status rather than grepping the payload.
mcp_status() { # mcp_status <token> <session> <tool>
  curl -s -o /dev/null -w '%{http_code}' -X POST "$GATEWAY_URL/mcp" \
    -H "authorization: Bearer $1" -H "mcp-session-id: $2" \
    -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"$3\",\"arguments\":{}}}"
}
expect "echo_whoami allowed for an mcp.call-only token" 200 "$(mcp_status "$MCP_ONLY" "$SID2" echo_whoami)"
expect "bin_get refused for the same token"             400 "$(mcp_status "$MCP_ONLY" "$SID2" bin_get)"
log "A disallowed tool is not merely hidden from tools/list; calling it by name is"
log "refused outright."

hdr "5. A note on writing those rules"
cat <<'EOT'
  Two things cost real time to work out, and both are in the config comments:

    mcp.tool.name is the name sent to the upstream target, not the prefixed name
    the client sees. The client calls echo_whoami; the rule sees whoami. Select
    the server with mcp.tool.target instead of matching a prefix on the name.

    Guard optional claims. A machine token has scope and no cognito:groups, a
    human token the reverse. An unguarded reference to an absent claim makes the
    expression fail rather than return false, and a failed allow rule refuses.
EOT

hdr "6. The second issuer, for clients that register themselves"
cat <<EOT
  Cognito handles everything above. What it cannot do is Dynamic Client
  Registration, and agentgateway has no Cognito adapter, so an MCP client that
  discovers the authorization server and registers itself cannot complete the flow.

  agentgateway does ship native MCP OAuth adapters for Auth0, Keycloak, Okta,
  Descope, authentik and Entra ID. The /mcp-dcr route uses Auth0 for exactly that,
  which also means this one gateway is validating two issuers at once.

  Point a DCR-capable client at:
    $GATEWAY_URL/mcp-dcr

  For example, in Claude Code:
    claude mcp add --transport http agw-lab $GATEWAY_URL/mcp-dcr
EOT
echo
log "The DCR route's metadata, adapted for Auth0:"
curl -s "$GATEWAY_URL/.well-known/oauth-protected-resource/mcp-dcr" | jq . | sed 's/^/    /'
echo
curl -s "$GATEWAY_URL/.well-known/oauth-authorization-server/mcp-dcr" | jq '{issuer, authorization_endpoint, token_endpoint, registration_endpoint}' | sed 's/^/    /'

hdr "7. The session"
log "This is the session id the gateway issued:"
echo "    ${SID:0:80}..."
log ""
log "That is not a lookup key. It is the session state itself: which targets are in"
log "the session and their upstream session ids, encrypted with AES-256-GCM using"
log "the fleet-wide config.session.key. Any node holding the same key can decrypt"
log "a session any other node issued, which is why the target group has stickiness"
log "switched off. scripts/21-ha-mcp-session.sh proves it."

summary
