# Only protocol handshakes, propagation waits and bounded request loops live here.
# The console's Commands tab expands these functions beside the calling command.

dd_mcp() { # <JWT> <method> [params JSON] [URL], a protocol check from the kagent agent runtime
  local token="$1" method="$2" params="${3:-}" url="${4:-$DD_URL/mcp}" headers session body
  [ -n "$params" ] || params='{}'
  headers=$(kubectl --context kind-mesh1 -n dd-agents exec deploy/defence-agent -- curl -fsS --max-time 15 -D - \
    "$url" -H "Authorization: Bearer $token" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"defence-lab","version":"1"}}}') || return
  session=$(printf '%s\n' "$headers" | tr -d '\r' | sed -n 's/^[Mm][Cc][Pp]-[Ss]ession-[Ii]d: *//p')
  [ -n "$session" ] || { printf 'No MCP session returned\n'; return 1; }
  kubectl --context kind-mesh1 -n dd-agents exec deploy/defence-agent -- curl -fsS --max-time 15 \
    "$url" -H "Authorization: Bearer $token" -H "Mcp-Session-Id: $session" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null || return
  body=$(jq -nc --arg method "$method" --argjson params "$params" '{jsonrpc:"2.0",id:2,method:$method,params:$params}') || return
  kubectl --context kind-mesh1 -n dd-agents exec deploy/defence-agent -- curl -sS --max-time 15 \
    "$url" -H "Authorization: Bearer $token" -H "Mcp-Session-Id: $session" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d "$body" \
    | jq -Rc 'rtrimstr("\r") | select(length > 0 and (startswith("event:") | not)) | ltrimstr("data: ") | . as $s | try fromjson catch $s'
}

dd_wait_policy() { # <EnterpriseAgentgatewayPolicy>, current generation accepted and attached
  local attempt
  for attempt in $(seq 1 45); do
    if kubectl --context kind-mesh1 -n dd-gateway get enterpriseagentgatewaypolicy "$1" -o json \
      | jq -e '.metadata.generation as $g | [.status.ancestors[]?.conditions[]? | select(.type == "Accepted" or .type == "Attached")] | length >= 2 and all(.status == "True" and .observedGeneration == $g)' >/dev/null; then
      sleep 2
      printf '%s Accepted and Attached\n' "$1"
      return 0
    fi
    sleep 1
  done
  printf 'Policy not ready: %s\n' "$1"; return 1
}

dd_wait_rate() { # Wait for the rate-limiter itself, not just the gateway controller.
  local attempt
  for attempt in $(seq 1 60); do
    if kubectl --context kind-mesh1 -n dd-gateway get ratelimitconfig dd-per-person -o json \
      | jq -e '.status.state == "ACCEPTED" and .status.observedGeneration == .metadata.generation' >/dev/null; then
      sleep 3
      printf 'dd-per-person ACCEPTED at current generation\n'; return 0
    fi
    sleep 1
  done
  printf 'Rate limiter has not loaded dd-per-person\n'; return 1
}

dd_burst() { # <open|limited> [count]; fresh Alice/Bob subjects give a fresh per-identity bucket.
  local mode="$1" count="${2:-6}" run alice bob code i ok=0 limited=0
  [[ "$count" =~ ^[0-9]+$ ]] && [ "$count" -ge 5 ] && [ "$count" -le 20 ] || return 1
  run=$(python3 -c 'import uuid; print(uuid.uuid4().hex[:10])')
  alice=$(python3 "$DD/identity.py" token --user "alice-$run") || return
  bob=$(python3 "$DD/identity.py" token --user "bob-$run") || return
  for i in $(seq 1 "$count"); do
    code=$(kubectl --context kind-mesh1 -n dd-agents exec deploy/defence-agent -- curl -sS --max-time 30 -o /dev/null -w '%{http_code}' \
      "$DD_URL/v1/chat/completions" -H "Authorization: Bearer $alice" -H 'Content-Type: application/json' \
      -d '{"model":"claude-haiku-4-5","max_tokens":16,"messages":[{"role":"user","content":"Reply only READY"}]}') || return
    printf 'Alice request %s: HTTP %s\n' "$i" "$code"
    case "$code" in 200) ok=$((ok+1));; 429) limited=$((limited+1));; *) return 1;; esac
    sleep 0.15
  done
  code=$(kubectl --context kind-mesh1 -n dd-agents exec deploy/defence-agent -- curl -sS --max-time 30 -o /dev/null -w '%{http_code}' \
    "$DD_URL/v1/chat/completions" -H "Authorization: Bearer $bob" -H 'Content-Type: application/json' \
    -d '{"model":"claude-haiku-4-5","max_tokens":16,"messages":[{"role":"user","content":"Reply only READY"}]}') || return
  printf 'Bob request: HTTP %s\nAlice totals: accepted=%s limited=%s\n' "$code" "$ok" "$limited"
  [ "$code" = 200 ] || return 1
  if [ "$mode" = open ]; then [ "$ok" -eq "$count" ] && [ "$limited" -eq 0 ];
  else [ "$ok" -ge 1 ] && [ "$limited" -ge 1 ]; fi
}
