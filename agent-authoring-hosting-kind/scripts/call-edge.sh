#!/usr/bin/env bash
# call-edge.sh: the published route, first without a token and then with one.
#
# The HTTPRoute on the ingress gateway carries a Strict JWT policy, so the first call is
# refused before it reaches the backend. With a token from the Keycloak realm the call
# goes through, and the backend's own policy decides which tools that user sees.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../agent-authoring-contract-kind/scripts/lib.sh
source "$SCRIPT_DIR/../../agent-authoring-contract-kind/scripts/lib.sh"
export INGRESS_GATEWAY="${INGRESS_GATEWAY:-ar-ingress}"
export INGRESS_GATEWAY_NS="${INGRESS_GATEWAY_NS:-agentgateway-system}"
LB="$(kc -n "$INGRESS_GATEWAY_NS" get gateway "$INGRESS_GATEWAY" -o jsonpath='{.status.addresses[0].value}')"
URL="http://contained-tools.${LB}.sslip.io/mcp"
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"laptop","version":"1"}}}'
H=(-H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream')

echo "POST $URL"
echo "  no token          → HTTP $(curl -s -m 10 -o /dev/null -w '%{http_code}' -X POST "$URL" "${H[@]}" -d "$INIT")"
T="$(mint_token)"; [[ -n "$T" ]] || die "no token: set KAGENT_TOKEN or KEYCLOAK_URL"
SID="$(curl -s -m 10 -D - -o /dev/null -X POST "$URL" -H "Authorization: Bearer $T" "${H[@]}" -d "$INIT" | tr -d '\r' | awk 'tolower($1)=="mcp-session-id:"{print $2}')"
[[ -n "$SID" ]] || die "initialize with a token returned no Mcp-Session-Id"
echo "  token for $AS_USER → HTTP 200, MCP session opened"
curl -s -m 10 -X POST "$URL" -H "Authorization: Bearer $T" -H "Mcp-Session-Id: $SID" "${H[@]}" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | sed 's/^data: //' | grep '^{' | head -1 \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); t=sorted(x["name"] for x in d.get("result",{}).get("tools",[])); print("  tools/list        →", len(t), "tool(s):", " ".join(t))'
