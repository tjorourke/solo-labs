#!/bin/bash
# Check everything the build needs before it spends any money.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools
require_aws

fails=0
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else warn "$1"; fails=$((fails+1)); fi; }

hdr "Account"
log "identity: $(aws sts get-caller-identity --query 'Arn' --output text | sed 's#/[^/]*$#/<redacted>#')"

hdr "Route53"
if [[ -z "${LAB_ROUTE53_ZONE:-}" ]]; then
  warn "set LAB_ROUTE53_ZONE=<your public hosted zone, e.g. example.com>"
  warn "HTTPS is required: Cognito refuses non-localhost http redirect URIs, so the admin UI"
  warn "OIDC flow cannot work without a certificate, and ACM needs a zone to validate in."
  fails=$((fails+1))
else
  zone_id="$(aws route53 list-hosted-zones-by-name --dns-name "$LAB_ROUTE53_ZONE" \
    --query "HostedZones[?Name=='${LAB_ROUTE53_ZONE}.'].Id | [0]" --output text 2>/dev/null)"
  if [[ "$zone_id" == "None" || -z "$zone_id" ]]; then
    warn "no public hosted zone found for '$LAB_ROUTE53_ZONE' in this account"
    log  "zones present:"
    aws route53 list-hosted-zones --query 'HostedZones[?Config.PrivateZone==`false`].Name' --output text | tr '\t' '\n' | sed 's/^/       /'
    fails=$((fails+1))
  else
    ok "hosted zone $LAB_ROUTE53_ZONE ($zone_id)"
  fi
fi

hdr "Identity"
ok "Cognito is created by the Terraform in this lab; there is nothing to sign up for"
log "It covers JWT validation, CEL authorization on claims, machine-to-machine"
log "tokens, and browser login for the admin UI."
log ""
log "Not covered: MCP clients that register themselves through OAuth Dynamic Client"
log "Registration. Cognito has no DCR and neither does any other AWS service. To add"
log "that, put a second issuer on its own route; the shape is written out in"
log "config/config.yaml just above the LLM section. agentgateway has native adapters"
log "for auth0, keycloak, okta, descope, authentik and entra."
if [[ -n "${LAB_AUTH0_ISSUER:-}" ]]; then
  if curl -sf --max-time 10 "$LAB_AUTH0_ISSUER/.well-known/openid-configuration" >/dev/null; then
    ok "LAB_AUTH0_ISSUER is set and reachable, so you can add that route if you want it"
  else
    warn "LAB_AUTH0_ISSUER is set but $LAB_AUTH0_ISSUER/.well-known/openid-configuration is unreachable"
  fi
fi

hdr "LLM provider keys"
for v in OPENAI_API_KEY ANTHROPIC_API_KEY; do
  if [[ -n "${!v:-}" ]]; then ok "$v is set"; else
    warn "$v is not set; that provider's models will fail at request time"
  fi
done

hdr "Bedrock"
model="${LAB_BEDROCK_MODEL:-us.anthropic.claude-sonnet-4-5-20250929-v1:0}"
if aws bedrock list-inference-profiles --query "inferenceProfileSummaries[?inferenceProfileId=='$model'].inferenceProfileId | [0]" \
     --output text 2>/dev/null | grep -q .; then
  ok "inference profile $model is available"
else
  warn "inference profile $model was not found in $AWS_REGION"
  log  "available Anthropic profiles:"
  aws bedrock list-inference-profiles \
    --query "inferenceProfileSummaries[?contains(inferenceProfileId, 'anthropic')].inferenceProfileId" \
    --output text 2>/dev/null | tr '\t' '\n' | sed 's/^/       /' | head -10
  fails=$((fails+1))
fi

hdr "Service quotas and capacity"
check "at least 3 availability zones" \
  "[ \$(aws ec2 describe-availability-zones --query 'length(AvailabilityZones)' --output text) -ge 3 ]"
eips_used="$(aws ec2 describe-addresses --query 'length(Addresses)' --output text)"
eips_max="$(aws service-quotas get-service-quota --service-code ec2 --quota-code L-0263D0A3 \
             --query 'Quota.Value' --output text 2>/dev/null || echo 5)"
if (( $(printf '%.0f' "$eips_max") - eips_used >= 3 )); then
  ok "elastic IP headroom: $eips_used in use of ${eips_max%.*} (the lab needs 3, or 1 with single_nat_gateway)"
else
  warn "not enough elastic IP headroom for 3 NAT gateways; set single_nat_gateway = true"
  fails=$((fails+1))
fi

hdr "Cost"
cat <<'EOT'
  This lab runs roughly $0.45-0.55 per hour with three NAT gateways:
    3 x t4g.medium                    ~$0.10/h
    1 x ALB                           ~$0.03/h + LCU
    Aurora Serverless v2, 2 x 0.5 ACU ~$0.12/h at the floor
    2 x cache.t4g.micro               ~$0.03/h
    3 x NAT gateway                   ~$0.14/h + data
  Set single_nat_gateway = true and redis_node_count = 1 to bring it to about $0.35/h.
  Tear it down with scripts/teardown.sh when you are finished.
EOT

if (( fails > 0 )); then
  hdr "$fails preflight check(s) need attention before scripts/01-apply.sh"
  exit 1
fi
hdr "preflight passed"
