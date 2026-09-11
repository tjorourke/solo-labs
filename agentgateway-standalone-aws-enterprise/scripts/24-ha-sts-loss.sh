#!/bin/bash
# Lose the STS on one node and prove the node takes itself out of service.
#
# This is the failure the docs warn about and the one worth rehearsing: a proxy
# whose STS has died keeps serving every user whose token it has already cached,
# and answers 502 for everyone else. Most traffic succeeds, so the node looks
# healthy while a growing share of users fail, and the graph that would show it
# is a graph nobody has.
#
# The container bundle solves this by stopping the whole unit when either process
# exits. On EC2 the same rule is BindsTo in the systemd unit, and this script is
# the proof that it works.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_tools; require_aws; require_stack

POLL_OUT="$(mktemp)"
start_poll() { ( while :; do curl -s -m 5 -o /dev/null -w '%{http_code}\n' "$GATEWAY_URL/whoami" >>"$POLL_OUT" || echo 000 >>"$POLL_OUT"; sleep 0.5; done ) & POLL_PID=$!; }
stop_poll()  { kill "$POLL_PID" 2>/dev/null || true; }
trap stop_poll EXIT

hdr "Starting state"
fleet_table; echo; target_health
expect "three healthy targets to begin with" 3 "$(healthy_count)"

VICTIM="$(fleet_instances | head -1)"
log "victim: $VICTIM"
log "both processes on it, before:"
node_try "$VICTIM" 'systemctl is-active agentgateway agentgateway-sts | tr "\n" " "' | sed 's/^/    /'

hdr "Stop the STS, leave the proxy alone"
start_poll
sleep 5
node_exec "$VICTIM" 'systemctl stop agentgateway-sts' >/dev/null

log "BindsTo means systemd should stop the proxy with it, rather than leave it"
log "serving half the traffic:"
for i in $(seq 1 12); do
  st="$(node_try "$VICTIM" 'systemctl is-active agentgateway | tr -d "\n"')"
  printf '    t+%-3ss agentgateway=%s\n' $((i*5)) "${st:-?}"
  [[ "$st" == "inactive" || "$st" == "failed" ]] && break
  sleep 5
done
PROXY_STATE="$(node_try "$VICTIM" 'systemctl is-active agentgateway | tr -d "\n"')"
[[ "$PROXY_STATE" == "active" ]] && { warn "the proxy is still running with a dead STS: this node is half-serving"; FAIL=$((FAIL+1)); } \
  || ok "the proxy stopped with its STS, so the node cannot half-serve"

hdr "The load balancer notices"
for i in $(seq 1 24); do
  h="$(healthy_count)"
  printf '    t+%-3ss healthy=%s\n' $((i*5)) "$h"
  [[ "$h" == "2" ]] && break
  sleep 5
done
expect "the ALB dropped it to two healthy targets" 2 "$(healthy_count)"

sleep 5
stop_poll
total=$(wc -l <"$POLL_OUT" | tr -d ' ')
good=$(grep -c '^200$' "$POLL_OUT" || true)
printf '    traffic during the failure: %s requests, %s succeeded, %s failed\n' "$total" "$good" "$(( total - good ))"
: >"$POLL_OUT"

hdr "Token exchange still works on the survivors"
TOK="$(mint_token all)"
SID="$(mcp_init "$TOK")"
UP="$(mcp_rpc "$TOK" "$SID" \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"exchanged_headers","arguments":{}}}' \
  | jq -r '.result.content[0].text // "{}"' | jq -r '.headers.authorization // empty' | sed 's/^[Bb]earer //')"
if [[ -n "$UP" ]]; then
  ok "an exchanged request was served by one of the two remaining nodes"
  jwt_payload "$UP" | jq '{iss, sub}' | sed 's/^/    /'
else
  warn "no exchanged token came back while a node was down"
  FAIL=$((FAIL+1))
fi
log "The STS mints rather than stores, so the surviving nodes need nothing from"
log "the one that went away. They sign with the same key, so the token they mint"
log "validates against the same JWKS as the one that node would have issued."

hdr "Restore"
node_exec "$VICTIM" 'systemctl start agentgateway-sts agentgateway' >/dev/null
for i in $(seq 1 24); do
  h="$(healthy_count)"; printf '    t+%-3ss healthy=%s\n' $((i*5)) "$h"
  [[ "$h" == "3" ]] && break
  sleep 5
done
expect "back to three healthy targets" 3 "$(healthy_count)"
node_try "$VICTIM" 'systemctl is-active agentgateway agentgateway-sts | tr "\n" " "' | sed 's/^/    /'

summary
