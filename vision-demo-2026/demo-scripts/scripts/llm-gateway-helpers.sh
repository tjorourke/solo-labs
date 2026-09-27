# llm-gateway-helpers.sh — small curl wrappers the demo-7 notebook reuses.
# Sourced by the notebook's Connect cell (needs $GATEWAY exported).
#
#   try_model <token|""> <model> [prompt]   one chat completion, prints HTTP code
#   status <curl args...>                   any request, prints HTTP code
#   mcp_tools <token>                       MCP handshake, lists visible tools
#   mcp_call <token> <tool> <args-json>     MCP handshake + one tool call
#   burn_tokens <name> <token>              requests until that user is limited
#   wait_ratelimit <name>                   until the rate limiter has loaded a RateLimitConfig
#   wait_budget <name>                      until a budget is compiled and loaded

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
    | sed -e '/^event:/d' -e 's/^data: //' | jq -r '.result.tools[].name'
}

mcp_call() {  # <token> <tool> <args-json>
  local S=$(_mcp_session "$1")
  curl -sS -m 20 -X POST "http://$GATEWAY/mcp" -H "Authorization: Bearer $1" \
    -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' \
    -H "mcp-session-id: $S" \
    -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"'$2'","arguments":'$3'}}' \
    | sed -e '/^event:/d' -e 's/^data: //' | jq -c 'if .error then {denied: .error.message} else {result: (.result.content[0].text // (.result|tostring) | .[:70])} end'
}

# A limit only bites once the rate limiter has loaded it, and right after a reset or
# a gateway restart that takes longer than a fixed pause. The rate limiter marks a
# RateLimitConfig ACCEPTED for the current generation when it has it, so wait on that.
_rlc_loaded() {  # <RateLimitConfig name>
  [ "$(kubectl -n "$NS" get ratelimitconfig "$1" \
    -o jsonpath='{.status.state}/{.status.observedGeneration}/{.metadata.generation}' 2>/dev/null \
    | awk -F/ '$1=="ACCEPTED" && $2==$3 {print "yes"}')" = yes ]
}

wait_ratelimit() {  # <RateLimitConfig name>
  local i
  for i in $(seq 1 60); do _rlc_loaded "$1" && break; sleep 2; done
  sleep 5
}

wait_budget() {  # <EnterpriseAgentgatewayBudget name> — the controller compiles it to agw-budget-<name>-<hash>
  local i rlc
  for i in $(seq 1 60); do
    rlc=$(kubectl -n "$NS" get ratelimitconfig -o name 2>/dev/null | grep "/agw-budget-$1" | head -1)
    [ -n "$rlc" ] && _rlc_loaded "${rlc#*/}" && break
    sleep 2
  done
  sleep 5
}

# Token spend is added to the counter after each response, and not always in time
# for the very next request, so four quick requests can all get through. Keep
# asking, a few seconds apart and inside one minute, until the user is limited.
burn_tokens() {  # <name> <token> [max requests]
  local i code
  for i in $(seq 1 "${3:-10}"); do
    code=$(try_model "$2" anything-else "write a haiku")
    echo "  $1 request $i: $code"
    [ "$code" = "HTTP 429" ] && return 0
    sleep 3
  done
}
