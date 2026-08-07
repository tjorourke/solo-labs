#!/usr/bin/env bash
# ai-gateway-reset.sh — put Part 7 back to a clean demo state.
#
# Removes everything the demo-7 notebook creates (backends, routes, policies,
# rate limits, budgets, virtual keys) and restarts the gateway and the rate
# limiter, which clears provider evictions, token buckets and budget counters.
# The platform from ai-gateway.sh (gateway, model servers, MCP server, cost
# catalog) stays up.
#
#   ./demo-scripts/ai-gateway-reset.sh
set -Eeuo pipefail
CTX="${CTX:-kind-mesh1}"
NS="${NS:-agentgateway-system}"

kubectl --context "$CTX" -n "$NS" delete \
  httproute/models httproute/resilient httproute/service-models httproute/mcp \
  enterpriseagentgatewaybackend/azure-gpt5 enterpriseagentgatewaybackend/bedrock-haiku \
  enterpriseagentgatewaybackend/anthropic-claude \
  enterpriseagentgatewaybackend/resilient-models enterpriseagentgatewaybackend/mcp-hub \
  enterpriseagentgatewaypolicy/models-jwt enterpriseagentgatewaypolicy/identity-metrics \
  enterpriseagentgatewaypolicy/models-access enterpriseagentgatewaypolicy/models-ratelimit \
  enterpriseagentgatewaypolicy/resilient-health enterpriseagentgatewaypolicy/service-models-auth \
  enterpriseagentgatewaypolicy/mcp-jwt \
  agentgatewaypolicy/extract-model agentgatewaypolicy/mcp-tool-authz \
  ratelimitconfig/per-user-tokens enterpriseagentgatewaybudget/service-budgets \
  secret/team-data-platform-keys --ignore-not-found
kubectl --context "$CTX" -n ai-models scale deploy/azure-openai --replicas=1 >/dev/null
# fresh rate-limit buckets + provider eviction state. Budget spend is tracked
# durably per key per day (by design, a restart never resets an allowance), so
# the notebook's §6 mints a fresh virtual key each run instead.
kubectl --context "$CTX" -n "$NS" rollout restart \
  deploy/ext-cache-enterprise-agentgateway deploy/rate-limiter-enterprise-agentgateway deploy/ai-gateway
kubectl --context "$CTX" -n "$NS" rollout status deploy/ext-cache-enterprise-agentgateway --timeout=120s
kubectl --context "$CTX" -n "$NS" rollout status deploy/rate-limiter-enterprise-agentgateway --timeout=120s
kubectl --context "$CTX" -n "$NS" rollout status deploy/ai-gateway --timeout=120s
echo "reset: clean slate (platform still up)"
