#!/usr/bin/env bash
# mcp.sh <method> [params-json] — one MCP call against the demo gateway, session handled.
#
# The endpoint is a *.<ip>.sslip.io name, so the address is already in the name. We pull
# it out and hand it to curl with --resolve rather than asking a resolver, because
# plenty of home-router and ISP resolvers refuse to return a private address for a
# public name and the failure looks like the gateway being down.
set -euo pipefail
METHOD="${1:?usage: mcp.sh <method> [params-json]}"
PARAMS="${2:-}"
K="kubectl --context ${CTX:-kind-mesh1}"
LB="${LB:-$($K -n agentgateway-system get gateway ar-ingress -o jsonpath='{.status.addresses[0].value}')}"
EP="${MCP:-http://github-mcp.${LB}.sslip.io/}"
HOST=$(printf '%s' "$EP" | sed -E 's#^https?://##; s#[:/].*$##')
IP=$(printf '%s' "$HOST" | sed -nE 's#.*[.]([0-9]{1,3}[.][0-9]{1,3}[.][0-9]{1,3}[.][0-9]{1,3})[.]sslip[.]io$#\1#p')
RESOLVE=(); [ -n "$IP" ] && RESOLVE=(--resolve "$HOST:80:$IP")
H=(-H "Content-Type: application/json" -H "Accept: application/json, text/event-stream")
HDR=$(mktemp)
curl -s -m 60 -X POST "$EP" "${RESOLVE[@]}" "${H[@]}" -D "$HDR" -o /dev/null \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"demo8","version":"1"}}}'
SID=$(grep -i '^mcp-session-id:' "$HDR" | tr -d '\r' | awk '{print $2}')
BODY=$(python3 -c 'import json,sys;print(json.dumps({"jsonrpc":"2.0","id":2,"method":sys.argv[1],"params":json.loads(sys.argv[2] or "{}")}))' "$METHOD" "$PARAMS")
curl -s -m 180 -X POST "$EP" "${RESOLVE[@]}" "${H[@]}" ${SID:+-H "Mcp-Session-Id: $SID"} -d "$BODY" \
  | sed 's/^data: //' | grep -v '^event:' | grep -v '^$'
