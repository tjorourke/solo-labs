#!/bin/bash
# Build the stack.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools
require_aws

[[ -n "${LAB_ROUTE53_ZONE:-}" ]] || die "set LAB_ROUTE53_ZONE=<your public hosted zone>; run scripts/00-preflight.sh first"

hdr "Plan"
tf init -input=false >/dev/null
tf plan -input=false -out=tfplan \
  -var "aws_region=$AWS_REGION" \
  -var "route53_zone_name=$LAB_ROUTE53_ZONE" \
  ${LAB_AUTH0_ISSUER:+-var "auth0_issuer=$LAB_AUTH0_ISSUER"} \
  -var "openai_api_key=${OPENAI_API_KEY:-}" \
  -var "anthropic_api_key=${ANTHROPIC_API_KEY:-}" \
  ${LAB_BEDROCK_MODEL:+-var "bedrock_model=$LAB_BEDROCK_MODEL"} \
  ${LAB_SINGLE_NAT:+-var "single_nat_gateway=$LAB_SINGLE_NAT"}

hdr "Apply"
log "Aurora and ElastiCache take the longest; expect 12-18 minutes for a cold build."
tf apply -input=false tfplan

hdr "Waiting for the fleet"
require_stack
log "gateway: $GATEWAY_URL"
log "DNS and the certificate can take a couple of minutes to settle."

if wait_for_gateway 90; then
  ok "gateway is answering"
else
  warn "the gateway is not answering yet. Check the target group and one node's bootstrap log:"
  warn "  scripts/02-verify.sh"
  warn "  aws ssm start-session --target \$(scripts/../scripts/lib.sh; fleet_instances | head -1)"
  exit 1
fi

hdr "Fleet"
fleet_table
echo
target_health

hdr "Next"
cat <<EOT
  gateway     $GATEWAY_URL
  admin UI    $GATEWAY_URL/ui   (sign in as $(tf_out cognito_test_user))
  password    $TF output -raw cognito_test_user_password   (run from terraform/)

  scripts/02-verify.sh          confirm the whole config is live on all three nodes
  scripts/10-routing.sh         HTTP routing, header manipulation, retries, CORS
  scripts/11-auth.sh            Cognito JWT auth and CEL authorization
  scripts/12-llm.sh             three providers, virtual models, guards, cost
  scripts/13-mcp.sh             multiplexed MCP, per-tool authorization
  scripts/15-ratelimit.sh       local vs global rate limits across the fleet
  scripts/20-ha-node-loss.sh    kill a node, then terminate one
  scripts/21-ha-mcp-session.sh  drive one MCP session across all three nodes
  scripts/22-ha-config-push.sh  one s3 cp reloads the fleet with no restart
  scripts/23-ha-ui-overlay.sh   a UI edit propagates through Aurora
  scripts/teardown.sh           destroy everything
EOT
