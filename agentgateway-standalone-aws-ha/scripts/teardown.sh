#!/bin/bash
# Destroy everything, then sweep for the things destroy tends to leave behind.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools
require_aws

hdr "About to destroy the whole lab"
if [[ -f "$TF_DIR/terraform.tfstate" ]]; then
  log "resources in state: $(cd "$TF_DIR" && "$TF" state list 2>/dev/null | wc -l | tr -d ' ')"
  log "gateway: $(tf_out gateway_url 2>/dev/null || echo unknown)"
else
  warn "no state file; nothing to destroy through OpenTofu. Running the orphan sweep only."
fi

if [[ "${LAB_FORCE:-}" != "1" ]]; then
  read -r -p "type 'destroy' to continue: " answer
  [[ "$answer" == "destroy" ]] || die "aborted"
fi

# The zone name is a required var, and terraform looks it up with a data source,
# so a wrong value fails the PLAN and nothing is destroyed. Defaulting to
# example.com therefore guaranteed "no matching Route 53 Hosted Zone found" for
# anyone who tore down without LAB_ROUTE53_ZONE still exported, which is most
# people, because teardown usually happens in a later shell than apply. Recover
# it from the state instead: the zone the environment was built against is
# recorded there.
if [[ -z "${LAB_ROUTE53_ZONE:-}" && -f "$TF_DIR/terraform.tfstate" ]]; then
  LAB_ROUTE53_ZONE="$(python3 - "$TF_DIR/terraform.tfstate" <<'PYEOF' 2>/dev/null || true
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit()
for r in d.get("resources",[]):
    if r.get("type")=="aws_route53_zone":
        for i in r.get("instances",[]):
            n=(i.get("attributes") or {}).get("name")
            if n: print(n.rstrip(".")); sys.exit()
PYEOF
)"
  [[ -n "$LAB_ROUTE53_ZONE" ]] && warn "LAB_ROUTE53_ZONE not set; using '$LAB_ROUTE53_ZONE' from the state"
fi

if [[ -f "$TF_DIR/terraform.tfstate" ]]; then
  [[ -n "${LAB_ROUTE53_ZONE:-}" ]] || die "set LAB_ROUTE53_ZONE to the hosted zone this was built with; terraform needs it to plan the destroy"
  hdr "Destroy"
  tf destroy -input=false -auto-approve \
    -var "aws_region=$AWS_REGION" \
    -var "route53_zone_name=${LAB_ROUTE53_ZONE}" \
    ${LAB_AUTH0_ISSUER:+-var "auth0_issuer=$LAB_AUTH0_ISSUER"} \
    -var "openai_api_key=${OPENAI_API_KEY:-}" \
    -var "anthropic_api_key=${ANTHROPIC_API_KEY:-}" \
    || warn "destroy reported errors; the sweep below may clear the blockers, then re-run"
fi

# ---------------------------------------------------------------------------
# Sweep. Everything the lab creates is tagged, so anything left behind with the
# lab's tag or name prefix is an orphan.
# ---------------------------------------------------------------------------
NAME="${LAB_NAME:-agw-ha}"

hdr "Sweep: orphaned resources"

log "instances still running with the lab tag:"
aws ec2 describe-instances \
  --filters "Name=tag:Lab,Values=agentgateway-standalone-aws-ha" "Name=instance-state-name,Values=running,pending,stopping,stopped" \
  --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output text | sed 's/^/    /' || true

log "load balancers:"
aws elbv2 describe-load-balancers --query "LoadBalancers[?starts_with(LoadBalancerName, '$NAME')].[LoadBalancerName,State.Code]" --output text | sed 's/^/    /' || true

log "network interfaces (these are what usually block a VPC delete):"
aws ec2 describe-network-interfaces \
  --filters "Name=description,Values=*$NAME*" \
  --query 'NetworkInterfaces[].[NetworkInterfaceId,Status,Description]' --output text | sed 's/^/    /' || true

log "Cognito user pool domains (a domain outlives its pool if destroy ordering slips):"
for pid in $(aws cognito-idp list-user-pools --max-results 60 \
              --query "UserPools[?starts_with(Name, '$NAME')].Id" --output text 2>/dev/null); do
  echo "    pool $pid"
done

log "secrets scheduled for deletion:"
aws secretsmanager list-secrets --include-planned-deletion \
  --query "SecretList[?starts_with(Name, '$NAME')].[Name,DeletedDate]" --output text 2>/dev/null | sed 's/^/    /' || true

log "log groups:"
for lg in $(aws logs describe-log-groups --log-group-name-prefix "/agentgateway/$NAME" \
             --query 'logGroups[].logGroupName' --output text 2>/dev/null); do
  echo "    deleting $lg"
  aws logs delete-log-group --log-group-name "$lg" 2>/dev/null || warn "could not delete $lg"
done

log "unattached elastic IPs:"
aws ec2 describe-addresses --query 'Addresses[?AssociationId==null].[PublicIp,AllocationId]' --output text | sed 's/^/    /' || true

log "ACM certificates for the lab hostname:"
if [[ -n "${LAB_ROUTE53_ZONE:-}" ]]; then
  aws acm list-certificates \
    --query "CertificateSummaryList[?ends_with(DomainName, '$LAB_ROUTE53_ZONE')].[DomainName,Status,CertificateArn]" \
    --output text | grep -i "${LAB_HOSTNAME:-agw}" | sed 's/^/    /' || echo "    (none)"
fi

hdr "Done"
cat <<'EOT'
  Anything listed above still exists. Elastic IPs and certificates cost nothing
  once unattached but are worth removing; a leftover network interface will block
  the VPC from going away, so delete it and re-run this script.

  Check the bill for the day with:
    aws ce get-cost-and-usage --time-period Start=$(date -u -v-1d +%F),End=$(date -u +%F) \
      --granularity DAILY --metrics UnblendedCost \
      --filter '{"Tags":{"Key":"Lab","Values":["agentgateway-standalone-aws-ha"]}}'
EOT
