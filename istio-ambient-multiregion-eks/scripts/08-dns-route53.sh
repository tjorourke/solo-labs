#!/usr/bin/env bash
# 08-dns-route53.sh — the DNS approach to regional failover: a Route 53
# failover record set over the two regional ingress NLBs.
#
# This is Approach A (contrast the Global Accelerator approach in 05/07). It
# needs a hosted zone you control. The record is a pair of failover CNAMEs:
#   PRIMARY   -> eu-central ingress NLB, tied to a health check
#   SECONDARY -> eu-west   ingress NLB, tied to a health check
# When the primary's health check fails, Route 53 hands out the secondary's
# value on the next resolution — cutover bounded by the record TTL.
#
#   HOSTED_ZONE_ID=Z... RECORD_NAME=region-echo.example.com ./08-dns-route53.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
require_aws

: "${HOSTED_ZONE_ID:?set HOSTED_ZONE_ID=<your Route 53 hosted zone id>}"
: "${RECORD_NAME:?set RECORD_NAME=<fqdn, e.g. region-echo.example.com>}"
TTL="${TTL:-15}"

CTX1="$(ctx_of "$NAME1" "$REGION1")"; CTX2="$(ctx_of "$NAME2" "$REGION2")"
[[ -n "$CTX1" && -n "$CTX2" ]] || die "missing kube contexts"

ing_nlb() { kubectl --context "$1" -n kgateway-system get svc \
  -l gateway.networking.k8s.io/gateway-name=ingress \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}'; }
ING1="$(ing_nlb "$CTX1")"; ING2="$(ing_nlb "$CTX2")"
[[ -n "$ING1" && -n "$ING2" ]] || die "ingress NLBs not found — run 05-ingress-ga.sh first"
ok "eu-central ingress: $ING1"
ok "eu-west    ingress: $ING2"

# One health check per region, TCP:80 against the ingress NLB. (These also back
# the standalone checks shown in the console.)
mk_check() { # mk_check <fqdn> <region-tag>
  local fqdn="$1" tag="$2" id
  id="$(aws route53 create-health-check --caller-reference "mesh-$tag-$(date +%s)" \
    --health-check-config "Type=TCP,FullyQualifiedDomainName=$fqdn,Port=80,RequestInterval=10,FailureThreshold=2" \
    --query 'HealthCheck.Id' --output text)"
  aws route53 change-tags-for-resource --resource-type healthcheck --resource-id "$id" \
    --add-tags "Key=Name,Value=mesh-$tag" "Key=lab,Value=mesh-multiregion" >/dev/null
  echo "$id"
}
step "Creating Route 53 health checks"
HC1="$(mk_check "$ING1" "$REGION1")"; ok "$REGION1 health check: $HC1"
HC2="$(mk_check "$ING2" "$REGION2")"; ok "$REGION2 health check: $HC2"

step "Creating the failover record set ($RECORD_NAME, TTL ${TTL}s)"
aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch "$(cat <<JSON
{"Changes":[
  {"Action":"UPSERT","ResourceRecordSet":{
    "Name":"$RECORD_NAME","Type":"CNAME","TTL":$TTL,
    "SetIdentifier":"$REGION1-primary","Failover":"PRIMARY",
    "HealthCheckId":"$HC1","ResourceRecords":[{"Value":"$ING1"}]}},
  {"Action":"UPSERT","ResourceRecordSet":{
    "Name":"$RECORD_NAME","Type":"CNAME","TTL":$TTL,
    "SetIdentifier":"$REGION2-secondary","Failover":"SECONDARY",
    "HealthCheckId":"$HC2","ResourceRecords":[{"Value":"$ING2"}]}}
]}
JSON
)" >/dev/null
ok "record set created"

echo
ok "DNS failover live at:  http://$RECORD_NAME/"
log "Resolves to $REGION1 while healthy; Route 53 hands out $REGION2 when the primary health check fails."
log "Demo: ./scripts/09-demo-dns-failover.sh $RECORD_NAME"
