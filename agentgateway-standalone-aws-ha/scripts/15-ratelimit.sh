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
cat <<'EOT'
  The LLM routes carry a remoteRateLimit of 10 a minute per caller, counted in
  ElastiCache. That is where a shared counter earns its keep: LLM calls cost money, so
  a limit that silently multiplies by the number of nodes is not a limit.

  The descriptor value is a CEL expression, so each caller gets its own bucket:
      value: 'has(jwt.sub) ? jwt.sub : apiKey.key'
EOT
log ""
log "Waiting for the current window to roll over."
sleep 62

TOK="$(mint_token all)"
log "Sending 20 requests as one caller, spread across three nodes by the load balancer:"
allowed=0; limited=0
for i in $(seq 1 20); do
  c="$(code -H "authorization: Bearer $TOK" -H 'content-type: application/json' \
       -d '{"model":"claude-bedrock","max_tokens":8,"messages":[{"role":"user","content":"ok"}]}' \
       "$GATEWAY_URL/v1/chat/completions")"
  printf '    %2d: %s\n' "$i" "$c"
  if [[ "$c" == "429" ]]; then limited=$((limited+1)); else allowed=$((allowed+1)); fi
done
log "allowed=$allowed  refused=$limited"
expect "exactly 10 allowed across the whole fleet" 10 "$allowed"
log "Three independent processes, and the limit still held at 10. That is the counter"
log "in ElastiCache doing the work rather than three separate token buckets."

log ""
log "A different caller has its own bucket, so it is unaffected:"
TOK2="$(mint_token llm-only)"
c2="$(code -H "authorization: Bearer $TOK2" -H 'content-type: application/json' \
     -d '{"model":"claude-bedrock","max_tokens":8,"messages":[{"role":"user","content":"ok"}]}' \
     "$GATEWAY_URL/v1/chat/completions")"
expect "a different caller is not rate limited" 200 "$c2"

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
node_try "$victim" 'systemctl stop agw-ratelimit' >/dev/null
log "stopped on $victim; sending 12 more requests (this caller's limit is already spent):"
open_count=0
for i in $(seq 1 12); do
  c="$(code -H "authorization: Bearer $TOK" -H 'content-type: application/json' \
       -d '{"model":"claude-bedrock","max_tokens":8,"messages":[{"role":"user","content":"ok"}]}' \
       "$GATEWAY_URL/v1/chat/completions")"
  printf '    %2d: %s\n' "$i" "$c"
  [[ "$c" == "200" ]] && open_count=$((open_count+1))
done
log "$open_count of 12 were allowed through."
log "Those came from $victim, which can no longer count and therefore fails open. The"
log "other two still refuse. That is failureMode: failOpen, and it is why this policy"
log "should not be carrying an authorization decision."
node_try "$victim" 'systemctl start agw-ratelimit' >/dev/null
ok "rate limit service restarted on $victim"

summary
