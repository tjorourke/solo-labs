#!/usr/bin/env bash
# Fresh MCP session for every call, including each negative test.
mcp_call() {
  local token=$1 tool=$2 args=$3 headers sid
  headers=$(incurl -D - -o /dev/null "$GW/mcp" -H "authorization: Bearer $token" -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"trustusbank","version":"1"}}}')
  sid=$(printf '%s' "$headers" | python3 -c 'import sys;print(next((x.split(":",1)[1].strip() for x in sys.stdin.read().splitlines() if x.lower().startswith("mcp-session-id:")),""))')
  [[ -n "$sid" ]] || { printf '%s\n' "$headers"; return 1; }
  incurl -o /dev/null "$GW/mcp" -H "authorization: Bearer $token" -H "mcp-session-id: $sid" -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  incurl -w '\nHTTP %{http_code}\n' "$GW/mcp" -H "authorization: Bearer $token" -H "mcp-session-id: $sid" -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"$tool\",\"arguments\":$args}}"
}
