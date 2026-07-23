#!/usr/bin/env bash
# teardown.sh — delete everything this lab created. Paid infrastructure: run
# this when you are done. Order matters — LB services and the Global
# Accelerator must go before the clusters, or they orphan.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
require_aws

CTX1="$(ctx_of "$NAME1" "$REGION1" || true)"
CTX2="$(ctx_of "$NAME2" "$REGION2" || true)"

step "Deleting Global Accelerator (if present)"
GA_ARN="$(aws globalaccelerator list-accelerators --region us-west-2 \
  --query "Accelerators[?Name=='mesh-multiregion'].AcceleratorArn" --output text 2>/dev/null || true)"
if [[ -n "$GA_ARN" && "$GA_ARN" != "None" ]]; then
  aws globalaccelerator update-accelerator --accelerator-arn "$GA_ARN" --no-enabled --region us-west-2 >/dev/null
  for L in $(aws globalaccelerator list-listeners --accelerator-arn "$GA_ARN" --region us-west-2 --query 'Listeners[].ListenerArn' --output text); do
    for EG in $(aws globalaccelerator list-endpoint-groups --listener-arn "$L" --region us-west-2 --query 'EndpointGroups[].EndpointGroupArn' --output text); do
      aws globalaccelerator delete-endpoint-group --endpoint-group-arn "$EG" --region us-west-2
    done
    aws globalaccelerator delete-listener --listener-arn "$L" --region us-west-2
  done
  echo "  waiting for accelerator to disable before delete..."; sleep 60
  aws globalaccelerator delete-accelerator --accelerator-arn "$GA_ARN" --region us-west-2 && ok "accelerator deleted"
fi

step "Deleting Route53 health checks tagged mesh-multiregion"
for HC in $(aws route53 list-health-checks --query 'HealthChecks[].Id' --output text 2>/dev/null); do
  TAG="$(aws route53 list-tags-for-resource --resource-type healthcheck --resource-id "$HC" \
    --query "ResourceTagSet.Tags[?Key=='lab'].Value" --output text 2>/dev/null || true)"
  [[ "$TAG" == "mesh-multiregion" ]] && aws route53 delete-health-check --health-check-id "$HC" && echo "  deleted $HC"
done

step "Deleting LoadBalancer services (releases the NLBs)"
for pair in "$CTX1:$REGION1" "$CTX2:$REGION2"; do
  ctx="${pair%%:*}"
  [[ -z "$ctx" ]] && continue
  kubectl --context "$ctx" delete svc -n istio-eastwest --all --ignore-not-found >/dev/null 2>&1 || true
  kubectl --context "$ctx" delete svc -n kgateway-system --all --ignore-not-found >/dev/null 2>&1 || true
  kubectl --context "$ctx" delete ns shop --ignore-not-found >/dev/null 2>&1 || true
done
ok "LB services deleted"; sleep 30

step "Deleting EKS clusters (10-15 min each)"
eksctl delete cluster --name "$NAME1" --region "$REGION1" --wait &
eksctl delete cluster --name "$NAME2" --region "$REGION2" --wait &
wait
ok "clusters deleted — verify no leftover NLBs/EIPs in $REGION1 and $REGION2"
