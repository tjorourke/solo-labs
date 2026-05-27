#!/usr/bin/env bash
# Step 2 — install MetalLB on both clusters and configure non-overlapping
# IP address pools derived from the docker kind network CIDR.
#
# Pool assignment:
#   east  <base>.255.200 – <base>.255.210  (agw-ingress LoadBalancer)
#   west  <base>.255.220 – <base>.255.230  (agw-ingress LoadBalancer)

set -Eeuo pipefail

METALLB_VERSION="${METALLB_VERSION:-v0.14.9}"
CLUSTER1="${CLUSTER1:-kind-east-ag}"
CLUSTER2="${CLUSTER2:-kind-west-ag}"

wait_ready() {
  local ctx="$1"
  echo "  [${ctx#kind-}] waiting for MetalLB controller..."
  kubectl --context "$ctx" -n metallb-system wait \
    --for=condition=Ready pod -l app=metallb,component=controller \
    --timeout=90s >/dev/null
}

apply_pool() {
  local ctx="$1" pool_start="$2" pool_end="$3"
  kubectl --context "$ctx" apply -f - <<EOF >/dev/null
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: kind-pool
  namespace: metallb-system
spec:
  addresses:
  - ${pool_start}-${pool_end}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: kind-l2
  namespace: metallb-system
EOF
  echo "  [${ctx#kind-}] pool ${pool_start}–${pool_end} configured"
}

# Derive the IPv4 kind docker network base (e.g. "172.22" from "172.22.0.0/16").
# docker returns both IPv4 and IPv6 subnets — use {{println}} to put each on its own
# line, then grep -v ':' to discard IPv6, leaving only the IPv4 CIDR.
KIND_CIDR="$(docker network inspect kind \
  --format '{{range .IPAM.Config}}{{println .Subnet}}{{end}}' 2>/dev/null \
  | grep -v ':' | head -1)"
if [[ -z "$KIND_CIDR" ]]; then
  echo "ERROR: 'kind' docker network not found — run 01-clusters.sh first"; exit 1
fi
BASE="$(echo "$KIND_CIDR" | cut -d. -f1,2)"
echo "  docker kind network: $KIND_CIDR  (base: $BASE)"

echo ""
echo "==> Installing MetalLB $METALLB_VERSION"
for ctx in "$CLUSTER1" "$CLUSTER2"; do
  echo "  [${ctx#kind-}] applying manifests..."
  kubectl --context "$ctx" apply -f \
    "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml" \
    >/dev/null
done

echo ""
echo "==> Waiting for controllers"
wait_ready "$CLUSTER1"
wait_ready "$CLUSTER2"

echo ""
echo "==> Configuring IP pools"
apply_pool "$CLUSTER1" "${BASE}.255.200" "${BASE}.255.210"
apply_pool "$CLUSTER2" "${BASE}.255.220" "${BASE}.255.230"

echo ""
echo "LoadBalancer services:"
for ctx in "$CLUSTER1" "$CLUSTER2"; do
  echo "  [${ctx#kind-}]"
  kubectl --context "$ctx" get svc -A --field-selector spec.type=LoadBalancer \
    -o custom-columns="NS:.metadata.namespace,NAME:.metadata.name,EXTERNAL-IP:.status.loadBalancer.ingress[0].ip" \
    2>/dev/null | grep -v "^NS" || echo "    (none yet)"
done

echo ""
echo "Next: ./scripts/03-istio.sh"
