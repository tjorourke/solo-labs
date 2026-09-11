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
# Guards run in the order they are listed, so the free ones go first. A rejection body
# is not necessarily JSON: the built-in default is plain text, and only the guard that
# sets its own rejection block returns the JSON shape configured for it.
guard_probe() { # guard_probe <label> <prompt>
  local body code
  body="$(curl -s -w '\n__CODE__%{http_code}' "$GATEWAY_URL/v1/chat/completions" \
    -H "x-api-key: $KEY" -H 'content-type: application/json' \
    -d "$(jq -nc --arg p "$2" '{model:"claude-bedrock", max_tokens:60, messages:[{role:"user",content:$p}]}')")"
  code="$(printf '%s' "$body" | sed -n 's/.*__CODE__//p')"
  payload="$(printf '%s' "$body" | sed 's/__CODE__.*//')"
  printf '    %-22s HTTP %s  %s\n' "$2" "$code" \
    "$(printf '%s' "$payload" | jq -r '.error.message // .choices[0].message.content' 2>/dev/null || printf '%s' "$payload" | tr -d '\n' | head -c 90)"
  echo "$code"
}

log "Layer one is a regex pass in the gateway process. A card number never reaches a"
log "provider, and costs nothing to check:"
c="$(guard_probe card "My card is 4111 1111 1111 1111, remember it" | tail -1)"
expect "card number rejected in-process" 403 "$c"

log ""
log "Layer two is a Bedrock Guardrail. Its policies live in the AWS console, so a"
log "security team changes what is blocked without touching config.yaml or restarting"
log "anything. This prompt hits a denied topic:"
c="$(guard_probe topic "What is our internal discount floor for the enterprise tier?" | tail -1)"
expect "denied topic blocked by the guardrail" 403 "$c"

log ""
log "And an ordinary prompt passes both layers:"
c="$(guard_probe ok "Name one benefit of a gateway, in five words" | tail -1)"
expect "an ordinary prompt is allowed" 200 "$c"

hdr "8. Streaming"
log "Streaming responses work through the ALB because its idle timeout is raised"
log "to 300s. The default 60s cuts long completions off mid-stream."
curl -s -N "$GATEWAY_URL/v1/chat/completions" -H "x-api-key: $KEY" \
  -H 'content-type: application/json' \
  -d '{"model":"claude-bedrock","stream":true,"max_tokens":60,"messages":[{"role":"user","content":"Count from 1 to 8"}]}' \
  | grep -c '^data:' | sed 's/^/    server-sent events received: /'

hdr "9. Cost, priced by the catalog"
cat <<'EOT'
  config/model-costs.json prices the Bedrock inference profile id, which the built-in
  catalog does not cover because a cross-region profile id is not a plain model name.

  The provider key in that file has to match the provider name the gateway reports,
  not the name you used in config.yaml. For Bedrock that is aws.bedrock. Get it wrong
  and requests still succeed, they simply arrive with a null cost.
EOT
one="$(fleet_instances | head -1)"
log ""
log "Recent priced requests, straight out of Aurora:"
node_try "$one" "set -a; . /etc/agentgateway/env; set +a; psql \"\$AGW_DATABASE_URL\" -P pager=off -c \"select gen_ai_provider_name as provider, gen_ai_response_model as model, input_tokens as in_tok, output_tokens as out_tok, cost, agentgateway_user as caller from request_logs order by started_at desc limit 8\"" | sed 's/^/    /'
log "Spend by provider across the whole fleet:"
node_try "$one" "set -a; . /etc/agentgateway/env; set +a; psql \"\$AGW_DATABASE_URL\" -P pager=off -c \"select gen_ai_provider_name as provider, count(*) as calls, sum(total_tokens) as tokens, round(sum(cost)::numeric,6) as usd from request_logs where cost is not null group by 1 order by 4 desc\"" | sed 's/^/    /'
log ""
log "The caller column comes from the virtual key metadata, so spend is attributable"
log "without the client having to tell you who it is."

hdr "10. Where to look next"
cat <<EOT
  $GATEWAY_URL/ui  ->  Analytics and the cost dashboard.

  Those pages read the request log in Aurora, which all three nodes write to. On a
  fleet with a per-node SQLite file you would be looking at a third of the traffic
  and would not know it.
EOT

summary
