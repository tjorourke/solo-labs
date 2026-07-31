#!/bin/bash
# Local versus global rate limits, and why the difference matters on a fleet.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_tools; require_aws; require_stack

AUDIENCE="$(tf_out cognito_api_audience)"
REDIS="$(tf_out redis_endpoint)"

hdr "1. The two policies"
cat <<EOT
  localRateLimit  is a token bucket inside one process. On the /api/public route it
                  allows 60 requests a minute. With three nodes behind a load
                  balancer, a client gets roughly 180.

  remoteRateLimit asks a rate limit service, which keeps its counters in
                  ElastiCache. On the MCP route it allows 10 a minute, and that is
                  10 for the fleet, because all three nodes count into:
                    $REDIS

  Each node runs its own copy of the rate limit service, so the check never leaves
  the box. The shared state is in ElastiCache, not in the service.
EOT

hdr "2. Local limit: the count is per node"
log "Firing 90 requests at /api/public, which is configured to allow 60 a minute."
log "If the limit were fleet-wide, 30 would be refused."
allowed=0; limited=0
for _ in $(seq 1 90); do
  c="$(code "$GATEWAY_URL/api/public/headers")"
  if [[ "$c" == "429" ]]; then limited=$((limited+1)); else allowed=$((allowed+1)); fi
done
log "allowed=$allowed  refused=$limited"
if (( allowed > 60 )); then
  ok "more than 60 got through, because each node keeps its own bucket"
else
  warn "only $allowed got through; the requests may not have spread across the nodes"
fi

hdr "3. Per-node buckets, seen directly"
log "Same load, counted by which node served it:"
for _ in $(seq 1 30); do whoami_node; done | sort | uniq -c | sed 's/^/    /'

hdr "4. Global limit: the count is fleet-wide"
log "The MCP route allows 10 requests a minute per caller, counted in ElastiCache."
log "Waiting for the current window to roll over."
sleep 62

TOK="$(mint_token all)"
init_mcp() {
  curl -s -o /dev/null -w '%{http_code}' -X POST "$GATEWAY_URL/mcp" \
    -H "authorization: Bearer $TOK" -H 'content-type: application/json' \
    -H 'accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"lab","version":"1"}}}'
}

log "Sending 16 MCP requests as one caller:"
allowed=0; limited=0
for i in $(seq 1 16); do
  c="$(init_mcp)"
  printf '    %2d: %s\n' "$i" "$c"
  if [[ "$c" == "429" ]]; then limited=$((limited+1)); else allowed=$((allowed+1)); fi
done
log "allowed=$allowed  refused=$limited"
expect "exactly 10 allowed across the whole fleet" 10 "$allowed"
log "The requests were spread across three processes and the limit still held at 10."
log "That is the counter in ElastiCache doing the work."

hdr "5. What happens when the counter is unreachable"
cat <<'EOT'
  The policy sets failureMode: failOpen, so if the rate limit service or
  ElastiCache is unavailable the gateway logs a warning and lets the request
  through rather than refusing everything.

  That is the right default for a rate limit and the wrong one for an
  authorization check. failClosed is the other option, and which you want depends
  on whether the limit is protecting a budget or protecting a secret.
EOT
log ""
log "Stopping the rate limit service on one node to watch it fail open:"
victim="$(fleet_instances | head -1)"
node_exec "$victim" 'systemctl stop agw-ratelimit' >/dev/null
log "stopped on $victim; sending 12 more MCP requests (the limit is already spent):"
for i in $(seq 1 12); do printf '    %2d: %s\n' "$i" "$(init_mcp)"; done
log "The 200s came from $victim, which can no longer count. The 429s came from the"
log "other two, which still can."
node_exec "$victim" 'systemctl start agw-ratelimit' >/dev/null
ok "rate limit service restarted on $victim"

summary
