# Only protocol handshakes, propagation waits and bounded request loops live here.
# The console's Commands tab expands these functions beside the calling command.

dd_public() { # The front door's load-balancer address.
  printf 'http://%s' "$(kubectl --context kind-mesh1 -n dd-gateway get gateway dd-gateway -o jsonpath='{.status.addresses[0].value}')"
}

_dd_curl() { # <agent|local> <JWT or empty> curl arguments...
  local where="$1" token="$2"; shift 2
  if [ -n "$token" ]; then set -- "$@" -H "Authorization: Bearer $token"; fi
  if [ "$where" = agent ]; then
    kubectl --context kind-mesh1 -n dd-agents exec deploy/defence-agent -- curl "$@"
  else
    curl "$@"
  fi
}

_dd_mcp() { # <agent|local> <URL> <JWT or empty> <method> [params JSON]
  local where="$1" url="$2" token="$3" method="$4" params="${5:-}" headers session body
  [ -n "$params" ] || params='{}'
  headers=$(_dd_curl "$where" "$token" -fsS --max-time 15 -D - -o /dev/null "$url" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"defence-lab","version":"1"}}}') || return
  session=$(printf '%s\n' "$headers" | tr -d '\r' | sed -n 's/^[Mm][Cc][Pp]-[Ss]ession-[Ii]d: *//p')
  [ -n "$session" ] || { printf 'No MCP session returned\n'; return 1; }
  _dd_curl "$where" "$token" -fsS --max-time 15 -o /dev/null "$url" -H "Mcp-Session-Id: $session" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' || return
  body=$(jq -nc --arg method "$method" --argjson params "$params" '{jsonrpc:"2.0",id:2,method:$method,params:$params}') || return
  _dd_curl "$where" "$token" -sS --max-time 15 "$url" -H "Mcp-Session-Id: $session" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d "$body" \
    | jq -Rc 'rtrimstr("\r") | select(length > 0 and (startswith("event:") | not)) | ltrimstr("data: ") | . as $s | try fromjson catch $s'
}

dd_mcp() { # <method> [params JSON] [URL]. A boundary check from the agent's runtime, carrying no token:
  # the only thing identifying the caller is the agent's SPIFFE identity.
  _dd_mcp agent "${3:-$DD_TOOLS}" "" "$1" "${2:-}"
}

dd_operator() { # <JWT> <method> [params JSON]. An operator's call from this machine through the front door.
  _dd_mcp local "$(dd_public)/mcp" "$1" "$2" "${3:-}"
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

dd_burst() { # <open|limited> [count]. Short agent turns through the front door as fresh Alice and Bob
  # subjects, so earlier checks have not used up their allowance.
  local mode="$1" count="${2:-6}" url run alice bob code i ok=0 limited=0 body
  [[ "$count" =~ ^[0-9]+$ ]] && [ "$count" -ge 5 ] && [ "$count" -le 20 ] || return 1
  url="$(dd_public)/a2a/"
  run=$(python3 -c 'import uuid; print(uuid.uuid4().hex[:10])')
  alice=$(python3 "$DD/identity.py" token --user "alice-$run") || return
  bob=$(python3 "$DD/identity.py" token --user "bob-$run") || return
  body='{"jsonrpc":"2.0","id":"rate","method":"message/send","params":{"message":{"role":"user","messageId":"rate-check","parts":[{"kind":"text","text":"Reply only READY"}]}}}'
  for i in $(seq 1 "$count"); do
    code=$(curl -sS --max-time 60 -o /dev/null -w '%{http_code}' "$url" -H "Authorization: Bearer $alice" \
      -H 'Content-Type: application/json' -d "$body") || return
    printf 'Alice request %s: HTTP %s\n' "$i" "$code"
    case "$code" in 200) ok=$((ok+1));; 429) limited=$((limited+1));; *) return 1;; esac
  done
  code=$(curl -sS --max-time 60 -o /dev/null -w '%{http_code}' "$url" -H "Authorization: Bearer $bob" \
    -H 'Content-Type: application/json' -d "$body") || return
  printf 'Bob request: HTTP %s\nAlice totals: accepted=%s limited=%s\n' "$code" "$ok" "$limited"
  [ "$code" = 200 ] || return 1
  if [ "$mode" = open ]; then [ "$ok" -eq "$count" ] && [ "$limited" -eq 0 ];
  else [ "$ok" -ge 1 ] && [ "$limited" -ge 1 ]; fi
}

dd_metrics() { # Request and guardrail counters from the front door and the mesh waypoint.
  local gw pod
  for gw in dd-gateway dd-waypoint; do
    pod=$(kubectl --context kind-mesh1 -n dd-gateway get pod -l gateway.networking.k8s.io/gateway-name=$gw -o jsonpath='{.items[0].metadata.name}') || return
    printf '# %s\n' "$gw"
    kubectl --context kind-mesh1 get --raw "/api/v1/namespaces/dd-gateway/pods/$pod:15020/proxy/metrics" \
      | grep -E '^agentgateway_(requests_total|guardrail_checks_total)'
  done
}
