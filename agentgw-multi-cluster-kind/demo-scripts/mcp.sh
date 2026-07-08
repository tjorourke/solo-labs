#!/usr/bin/env bash
# mcp.sh — talk to an agentgateway MCP endpoint over StreamableHTTP.
# The MCP endpoint needs an `initialize` handshake to mint a session id before
# any other call, so this wraps the handshake and prints just the useful bit.
#
# Usage:
#   ./demo-scripts/mcp.sh list                       # list every federated tool
#   ./demo-scripts/mcp.sh call <tool> '<json-args>'  # call one tool
#
# Env:
#   MCP_URL   full URL of the MCP endpoint (default: read the mcp-gateway LB on east)
#   CLUSTER1  east context (default kind-east-ag)

set -Eeuo pipefail
CLUSTER1="${CLUSTER1:-kind-east-ag}"

if [[ -z "${MCP_URL:-}" ]]; then
  GW="$(kubectl --context "$CLUSTER1" -n ai-tools get gateway mcp-gateway \
        -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)"
  [[ -n "$GW" ]] || { echo "mcp-gateway has no address yet — is it Programmed?" >&2; exit 1; }
  MCP_URL="http://${GW}:8080/mcp"
fi

hdr=(-H "Content-Type: application/json" -H "Accept: application/json,text/event-stream")

# 1) initialize → capture the session id from the response header
SID="$(curl -sS -D - -o /dev/null "$MCP_URL" "${hdr[@]}" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"lab","version":"1.0"}}}' \
  | awk -F': ' 'tolower($1)=="mcp-session-id"{print $2}' | tr -d '\r')"
[[ -n "$SID" ]] || { echo "initialize failed (no session id) — check the MCP backend targets" >&2; exit 1; }

# 2) notifications/initialized (required before other methods)
curl -sS -o /dev/null "$MCP_URL" "${hdr[@]}" -H "mcp-session-id: $SID" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'

case "${1:-list}" in
  list)
    curl -sS "$MCP_URL" "${hdr[@]}" -H "mcp-session-id: $SID" \
      -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
      | sed 's/^data: //' | grep -oE '"name":"[^"]+"' | cut -d'"' -f4 | sort
    ;;
  call)
    tool="${2:?tool name required}"; args="${3:-}"; [[ -n "$args" ]] || args='{}'
    curl -sS "$MCP_URL" "${hdr[@]}" -H "mcp-session-id: $SID" \
      -d "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"${tool}\",\"arguments\":${args}}}" \
      | sed 's/^data: //' | grep -oE '"(text|message)":"[^"]*"' | cut -d'"' -f4
    ;;
  *) echo "usage: mcp.sh [list | call <tool> '<json-args>']" >&2; exit 2 ;;
esac
