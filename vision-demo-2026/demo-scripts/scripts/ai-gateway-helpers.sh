# ai-gateway-helpers.sh — small curl wrappers the demo-7 notebook reuses.
# Sourced by the notebook's Connect cell (needs $GATEWAY exported).
#
#   try_model <token|""> <model> [prompt]   one chat completion, prints HTTP code
#   status <curl args...>                   any request, prints HTTP code
#   mcp_tools <token>                       MCP handshake, lists visible tools
#   mcp_call <token> <tool> <args-json>     MCP handshake + one tool call

try_model() {  # <token|""> <model> [prompt]
  curl -sS -m 60 -o /dev/null -w 'HTTP %{http_code}\n' "http://$GATEWAY/models/v1/chat/completions" \
    ${1:+-H "Authorization: Bearer $1"} -H 'content-type: application/json' \
    -d '{"model":"'$2'","messages":[{"role":"user","content":"'"${3:-hi}"'"}],"max_tokens":60}'
}

status() { curl -sS -m 60 -o /dev/null -w 'HTTP %{http_code}\n' "$@"; }

_mcp_session() {  # <token|"">
  curl -sS -m 20 -i -X POST "http://$GATEWAY/mcp" ${1:+-H "Authorization: Bearer $1"} \
    -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"demo","version":"1"}}}' \
    | grep -i '^mcp-session-id:' | awk '{print $2}' | tr -d '\r'
}

mcp_tools() {  # <token|""> — list the tools this identity can see
  local S=$(_mcp_session "$1")
  curl -sS -m 20 -X POST "http://$GATEWAY/mcp" ${1:+-H "Authorization: Bearer $1"} \
    -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' \
    -H "mcp-session-id: $S" -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
    | sed 's/^data: //' | jq -r '.result.tools[].name'
}

mcp_call() {  # <token> <tool> <args-json>
  local S=$(_mcp_session "$1")
  curl -sS -m 20 -X POST "http://$GATEWAY/mcp" -H "Authorization: Bearer $1" \
    -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' \
    -H "mcp-session-id: $S" \
    -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"'$2'","arguments":'$3'}}' \
    | sed 's/^data: //' | jq -c 'if .error then {denied: .error.message} else {result: (.result.content[0].text // (.result|tostring) | .[:70])} end'
}
