#!/usr/bin/env bash
# 05-ingress-ga.sh — demo 2 setup: regional ingress + Global Accelerator.
#
# kgateway in each cluster fronts the global service on an internet-facing NLB.
# AWS Global Accelerator sits over both NLBs with health checks — static
# anycast IPs, no DNS TTLs. Standalone Route53 health checks are created too,
# purely to show what a DNS-based failover would key on.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
require_aws

# versions.env exports KGW_VERSION without the v prefix — the OCI tags have it
KGW_VERSION="v${KGW_VERSION#v}"; : "${KGW_VERSION:=v2.2.0}"
CTX1="$(ctx_of "$NAME1" "$REGION1")"; CTX2="$(ctx_of "$NAME2" "$REGION2")"
[[ -n "$CTX1" && -n "$CTX2" ]] || die "missing kube contexts"

ingress() {
  local ctx="$1" name="$2"
  step "[$name] kgateway $KGW_VERSION + Gateway on an NLB"
  # kgateway's controller watches TLSRoute (experimental channel). The Gateway
  # API standard-install does NOT ship it, and eksctl clusters carry a
  # safe-upgrades ValidatingAdmissionPolicy that blocks experimental CRDs on top
  # of standard ones — remove it, then add TLSRoute, or kgateway crashloops on
  # "failed to list TLSRoute".
  kubectl --context "$ctx" delete validatingadmissionpolicybinding safe-upgrades.gateway.networking.k8s.io --ignore-not-found >/dev/null 2>&1 || true
  kubectl --context "$ctx" delete validatingadmissionpolicy safe-upgrades.gateway.networking.k8s.io --ignore-not-found >/dev/null 2>&1 || true
  kubectl --context "$ctx" apply -f \
    "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${GATEWAY_API_VERSION}/config/crd/experimental/gateway.networking.k8s.io_tlsroutes.yaml" >/dev/null
  helm --kube-context "$ctx" upgrade -i kgateway-crds oci://cr.kgateway.dev/kgateway-dev/charts/kgateway-crds \
    -n kgateway-system --create-namespace --version "$KGW_VERSION" --wait >/dev/null
  helm --kube-context "$ctx" upgrade -i kgateway oci://cr.kgateway.dev/kgateway-dev/charts/kgateway \
    -n kgateway-system --version "$KGW_VERSION" --wait >/dev/null
  kubectl --context "$ctx" apply -f - >/dev/null <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ingress
  namespace: kgateway-system
spec:
  gatewayClassName: kgateway
  # standard Gateway API infra annotations -> propagated onto the generated
  # LB Service. This is what makes it an NLB (Global Accelerator needs NLB,
  # not the default classic ELB). The kgateway.dev/service-annotations
  # Gateway annotation does NOT propagate in v2.2.0 — use this.
  infrastructure:
    annotations:
      service.beta.kubernetes.io/aws-load-balancer-type: nlb
  listeners:
    - name: http
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces: { from: All }
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: region-echo
  namespace: shop
spec:
  parentRefs:
    - name: ingress
      namespace: kgateway-system
  rules:
    - backendRefs:
        - name: region-echo
          port: 8080
EOF
  # externalTrafficPolicy: Local -> the NLB health check only passes on nodes
  # that actually run an ingress pod. Without this (Cluster mode), kube-proxy
  # answers the NodePort health check even with 0 ingress pods, so GA never sees
  # the region as unhealthy and never fails over. Also preserves client IP.
  sleep 8
  local svc
  svc="$(kubectl --context "$ctx" -n kgateway-system get svc -l gateway.networking.k8s.io/gateway-name=ingress -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  [[ -n "$svc" ]] && kubectl --context "$ctx" -n kgateway-system patch svc "$svc" \
    -p '{"spec":{"externalTrafficPolicy":"Local"}}' >/dev/null || true
  ok "[$name] ingress applied (externalTrafficPolicy=Local)"
}

ingress "$CTX1" "$NAME1"
ingress "$CTX2" "$NAME2"

step "Waiting for ingress NLB hostnames"
ing_host() {
  local ctx="$1" host=""
  for _ in $(seq 1 60); do
    host="$(kubectl --context "$ctx" -n kgateway-system get svc \
      -l gateway.networking.k8s.io/gateway-name=ingress \
      -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null)"
    [[ -n "$host" ]] && { echo "$host"; return 0; }
    sleep 5
  done
  return 1
}
ING1="$(ing_host "$CTX1")" || die "no ingress LB on $NAME1"
ING2="$(ing_host "$CTX2")" || die "no ingress LB on $NAME2"
ok "$REGION1 ingress: $ING1"
ok "$REGION2 ingress: $ING2"

nlb_arn() { # nlb_arn <region> <dns-name>
  aws elbv2 describe-load-balancers --region "$1" \
    --query "LoadBalancers[?DNSName=='$2'].LoadBalancerArn" --output text
}
ARN1="$(nlb_arn "$REGION1" "$ING1")"
ARN2="$(nlb_arn "$REGION2" "$ING2")"
[[ -n "$ARN1" && -n "$ARN2" ]] || die "could not resolve NLB ARNs (are these NLBs? GA needs NLB, not CLB)"

step "Global Accelerator over both regional NLBs (GA API lives in us-west-2)"
GA_ARN="$(aws globalaccelerator list-accelerators --region us-west-2 \
  --query "Accelerators[?Name=='mesh-multiregion'].AcceleratorArn" --output text)"
if [[ -z "$GA_ARN" || "$GA_ARN" == "None" ]]; then
  GA_ARN="$(aws globalaccelerator create-accelerator --name mesh-multiregion \
    --region us-west-2 --query 'Accelerator.AcceleratorArn' --output text)"
fi
LARN="$(aws globalaccelerator list-listeners --accelerator-arn "$GA_ARN" --region us-west-2 \
  --query 'Listeners[0].ListenerArn' --output text)"
if [[ -z "$LARN" || "$LARN" == "None" ]]; then
  LARN="$(aws globalaccelerator create-listener --accelerator-arn "$GA_ARN" \
    --protocol TCP --port-ranges FromPort=80,ToPort=80 \
    --region us-west-2 --query 'Listener.ListenerArn' --output text)"
fi
for pair in "$REGION1:$ARN1" "$REGION2:$ARN2"; do
  region="${pair%%:*}"; arn="${pair#*:}"
  EXISTS="$(aws globalaccelerator list-endpoint-groups --listener-arn "$LARN" --region us-west-2 \
    --query "EndpointGroups[?EndpointGroupRegion=='$region'].EndpointGroupArn" --output text)"
  if [[ -z "$EXISTS" || "$EXISTS" == "None" ]]; then
    aws globalaccelerator create-endpoint-group --listener-arn "$LARN" \
      --endpoint-group-region "$region" \
      --endpoint-configurations "EndpointId=$arn,Weight=100,ClientIPPreservationEnabled=false" \
      --health-check-port 80 --health-check-protocol TCP \
      --health-check-interval-seconds 10 --threshold-count 2 \
      --region us-west-2 >/dev/null
    ok "endpoint group: $region"
  fi
done
GA_DNS="$(aws globalaccelerator describe-accelerator --accelerator-arn "$GA_ARN" --region us-west-2 \
  --query 'Accelerator.DnsName' --output text)"
GA_IPS="$(aws globalaccelerator describe-accelerator --accelerator-arn "$GA_ARN" --region us-west-2 \
  --query 'Accelerator.IpSets[0].IpAddresses' --output text)"

step "Standalone Route53 health checks (what a DNS failover record would key on)"
for pair in "$REGION1:$ING1" "$REGION2:$ING2"; do
  region="${pair%%:*}"; host="${pair#*:}"
  HC_ID="$(aws route53 create-health-check --caller-reference "mesh-$region-$(date +%s)" \
    --health-check-config "Type=TCP,FullyQualifiedDomainName=$host,Port=80,RequestInterval=10,FailureThreshold=2" \
    --query 'HealthCheck.Id' --output text 2>/dev/null || true)"
  if [[ -n "$HC_ID" ]]; then
    aws route53 change-tags-for-resource --resource-type healthcheck --resource-id "$HC_ID" \
      --add-tags "Key=Name,Value=mesh-$region" "Key=lab,Value=mesh-multiregion" >/dev/null
    ok "health check $region: $HC_ID"
  fi
done

echo
ok "Global Accelerator: http://$GA_DNS  (static IPs: $GA_IPS)"
log "Demo: curl the GA address -> region answers; kill one region's ingress -> the other takes over in ~20-30s"
