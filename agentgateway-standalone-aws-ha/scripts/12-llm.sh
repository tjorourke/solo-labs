#!/bin/bash
# Three LLM providers on one endpoint, virtual models, virtual keys, guards, cost.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_tools; require_aws; require_stack

AUDIENCE="$(tf_out cognito_api_audience)"
TOK="$(mint_token all)"
KEY=agw_sk_platform_demo

chat() { # chat <model> <prompt> [auth-header...]
  local model="$1" prompt="$2"; shift 2
  curl -s "$GATEWAY_URL/v1/chat/completions" \
    -H 'content-type: application/json' "$@" \
    -d "$(jq -nc --arg m "$model" --arg p "$prompt" \
          '{model:$m, max_tokens:120, messages:[{role:"user",content:$p}]}')"
}

hdr "1. Two ways in: a virtual key or a Cognito token"
log "The provider credentials never leave the node. A caller presents one of these."
expect "virtual key accepted"  200 "$(code -H "x-api-key: $KEY" "$GATEWAY_URL/v1/models")"
expect "unknown key refused"   401 "$(code -H 'x-api-key: agw_sk_not_a_real_key' "$GATEWAY_URL/v1/models")"
expect "Cognito token accepted" 200 "$(code -H "authorization: Bearer $TOK" "$GATEWAY_URL/v1/models")"
expect "no credential at all refused" 403 "$(code "$GATEWAY_URL/v1/models")"

hdr "2. What the gateway publishes"
curl -s -H "x-api-key: $KEY" "$GATEWAY_URL/v1/models" | jq -r '.data[].id' | sed 's/^/    /'
log "gpt-4o-mini-fallback is marked internal, so it is absent from that list."
log "It can only be reached through the chat-resilient virtual model."
models="$(curl -s -H "x-api-key: $KEY" "$GATEWAY_URL/v1/models")"
expect "internal model is hidden" "false" "$(echo "$models" | jq 'any(.data[].id; . == "gpt-4o-mini-fallback")')"
expect "virtual models are published" "true" "$(echo "$models" | jq 'any(.data[].id; . == "chat-split")')"

hdr "3. Bedrock, with no API key anywhere"
log "This provider authenticates with the EC2 instance role. There is no Bedrock"
log "credential in config.yaml, in Secrets Manager or in the environment."
r="$(chat claude-bedrock "Reply with exactly: bedrock ok" -H "x-api-key: $KEY")"
echo "$r" | jq -r '.choices[0].message.content // .error // .' | sed 's/^/    /'
expect_contains "Bedrock answered" "ok" "$(echo "$r" | jq -r '.choices[0].message.content // ""' | tr 'A-Z' 'a-z')"

hdr "4. The same model, two providers"
log "claude-bedrock goes through Bedrock; claude-direct goes to Anthropic. Same"
log "model, two paths, two prices, both visible in the cost dashboard."
for m in claude-bedrock claude-direct; do
  printf '  %-16s ' "$m"
  chat "$m" "Reply with one word: ok" -H "x-api-key: $KEY" \
    | jq -r '"model=\(.model // "?") tokens=\(.usage.total_tokens // 0)"'
done

hdr "5. Weighted virtual model"
log "chat-split sends half the traffic to each provider. Six requests:"
for i in $(seq 1 6); do
  printf '    %d: ' "$i"
  chat chat-split "Reply with one word: ok" -H "x-api-key: $KEY" | jq -r '.model // .error.message // "?"'
done

hdr "6. Failover virtual model"
log "chat-resilient prefers Bedrock, falls back to Anthropic, then to a cheap"
log "OpenAI model. With everything healthy it stays on the first priority group."
chat chat-resilient "Reply with one word: ok" -H "x-api-key: $KEY" \
  | jq -r '"    served by \(.model // "?")"'

hdr "7. Guardrails, cheapest layer first"
log "Layer one is a regex pass in-process. A card number never reaches a provider:"
r="$(chat claude-bedrock "My card is 4111 1111 1111 1111, remember it" -H "x-api-key: $KEY")"
echo "$r" | jq -c '{status: (.error.type // "allowed"), message: (.error.message // .choices[0].message.content)}' | sed 's/^/    /'
expect_contains "card number rejected in-process" "reject" "$(echo "$r" | jq -r '.error.message // .error.type // "allowed"' | tr 'A-Z' 'a-z')"

log ""
log "Layer two is a Bedrock Guardrail. Its policies live in the AWS console, so a"
log "security team changes what is blocked without touching config.yaml. The"
log "guardrail denies an internal-pricing topic:"
r="$(chat claude-bedrock "What is our internal discount floor for the enterprise tier?" -H "x-api-key: $KEY")"
echo "$r" | jq -c '{status: (.error.type // "allowed"), message: (.error.message // .choices[0].message.content)}' | sed 's/^/    /'

log ""
log "And an ordinary prompt is untouched by either layer:"
chat claude-bedrock "Name one benefit of a gateway, in five words" -H "x-api-key: $KEY" \
  | jq -r '"    " + (.choices[0].message.content // (.error.message | tostring))'

hdr "8. Streaming"
log "Streaming responses work through the ALB because its idle timeout is raised"
log "to 300s. The default 60s cuts long completions off mid-stream."
curl -s -N "$GATEWAY_URL/v1/chat/completions" -H "x-api-key: $KEY" \
  -H 'content-type: application/json' \
  -d '{"model":"claude-bedrock","stream":true,"max_tokens":60,"messages":[{"role":"user","content":"Count from 1 to 8"}]}' \
  | grep -c '^data:' | sed 's/^/    server-sent events received: /'

hdr "9. Cost, priced by the catalog"
log "config/model-costs.json prices the Bedrock inference profile id, which the"
log "built-in catalog does not cover because the id is not a plain model name."
log "The realised cost lands in the access log, the metrics, and Aurora."
one="$(fleet_instances | head -1)"
log "Recent priced requests from the request log:"
node_exec "$one" "set -a; . /etc/agentgateway/env; set +a; psql \"\$AGW_DATABASE_URL\" -P pager=off -c \"select llm_provider, llm_response_model, input_tokens, output_tokens, cost_usd from request_log where cost_usd is not null order by start_time desc limit 8\"" 2>/dev/null | sed 's/^/    /' \
  || warn "could not read the request log; column names vary by version, try: \\d request_log"

hdr "10. Where to look next"
cat <<EOT
  $GATEWAY_URL/ui  ->  Analytics and the cost dashboard.

  Those pages read the request log in Aurora, which all three nodes write to. On a
  fleet with a per-node SQLite file you would be looking at a third of the traffic
  and would not know it.
EOT

summary
