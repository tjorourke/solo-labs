#!/bin/bash
# HTTP routing: matching, rewrites, header manipulation, retries, CORS, faults.
#
# Nothing here is AI-specific. The point is that the same binary and the same
# config file handle ordinary API traffic, so this is not a second gateway to run
# alongside the one you already have.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_tools; require_aws; require_stack

hdr "1. Which node answered"
log "/whoami is served in-process by every node, so it works even with no upstream."
curl -s "$GATEWAY_URL/whoami" | jq .
echo
log "Response headers carry the node identity too:"
curl -s -D - -o /dev/null "$GATEWAY_URL/whoami" | grep -iE '^x-agw-' | sed 's/^/    /'

hdr "2. Path rewriting"
log "The route matches /api/public and rewrites the prefix to / before forwarding."
path="$(curl -s "$GATEWAY_URL/api/public/headers" | jq -r .path)"
expect "the upstream sees the rewritten path" "/headers" "$path"

hdr "3. Header manipulation"
log "Sending x-internal-only, which the route is configured to strip."
body="$(curl -s -H 'x-internal-only: should-not-arrive' "$GATEWAY_URL/api/public/headers")"
# Compare against the node that served THIS request, not a separate one: the load
# balancer will happily send two requests to two different nodes.
served_by="$(echo "$body" | jq -r '.headers["x-served-by"] // ""')"
node_field="$(echo "$body" | jq -r '.node // ""')"
expect "x-served-by matches the node that answered" "$node_field" "$served_by"
expect "x-gateway-tier was added"    "public" "$(echo "$body" | jq -r '.headers["x-gateway-tier"] // "missing"')"
expect "x-internal-only was removed" "null"   "$(echo "$body" | jq -r '.headers["x-internal-only"]')"
echo "$body" | jq '.headers | with_entries(select(.key | startswith("x-")))'

hdr "4. Retries"
log "The route retries 502, 503 and 504 three times with a 100ms backoff."
log "Asking the upstream for a 503 exhausts the attempts and returns it:"
expect "503 is returned after the retries are exhausted" 503 "$(code "$GATEWAY_URL/api/public/status/503")"
log "A 500 is not in the retry list, so it comes straight back:"
expect "500 is not retried" 500 "$(code "$GATEWAY_URL/api/public/status/500")"

hdr "5. CORS"
log "Preflight from the gateway's own origin is allowed:"
curl -s -D - -o /dev/null -X OPTIONS "$GATEWAY_URL/api/public/headers" \
  -H "origin: $GATEWAY_URL" -H 'access-control-request-method: POST' \
  | grep -iE '^access-control-' | sed 's/^/    /'
log "Preflight from somewhere else gets no allow-origin header:"
other="$(curl -s -D - -o /dev/null -X OPTIONS "$GATEWAY_URL/api/public/headers" \
  -H 'origin: https://not-allowed.example' -H 'access-control-request-method: POST' \
  | grep -ci '^access-control-allow-origin' || true)"
expect "unlisted origin is not allowed" 0 "$other"

hdr "6. Fault injection"
log "The chaos route injects 500ms of latency into half of its requests, using a"
log "CEL expression rather than a fixed percentage field."
for i in $(seq 1 8); do
  t="$(curl -s -o /dev/null -w '%{time_total}' "$GATEWAY_URL/api/chaos/headers")"
  printf '    request %d: %ss\n' "$i" "$t"
done

hdr "7. Direct response"
log "The /whoami route never touches an upstream. Stop the echo service on every"
log "node and it still answers, which is why the HA scripts poll it."
expect "direct response works" 200 "$(code "$GATEWAY_URL/whoami")"

summary
