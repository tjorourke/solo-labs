#!/usr/bin/env bash
# Platform step 1: OSS agentgateway, set up for an inference gateway that classifies.
#
#   ./scripts/platform/10-agentgateway.sh
#
# Four things, in this order:
#   1. the Gateway API experimental channel. ExtProc rides on it; the standard channel does
#      not carry it. --server-side because the experimental CRDs carry a last-applied
#      annotation past the client-side limit.
#   2. the agentgateway CRDs chart.
#   3. the agentgateway chart with yaml/platform/10-agentgateway-values.yaml, whose one
#      setting is the controller flag that makes it honour those experimental CRDs.
#   4. the Gateway itself, ClusterIP, which the controller turns into a data-plane Deployment.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$HERE/scripts/lib.sh"
GWAPI_VERSION="${GWAPI_VERSION:-v1.6.1}"
AGW_VERSION="${AGW_VERSION:-v1.5.0}"

banner "the cluster this is going onto"
kubectl get nodes -o custom-columns='NODE:.metadata.name,READY:.status.conditions[-1].status,GPU:.status.allocatable.nvidia\.com/gpu,ROLE:.metadata.labels.role'
if ! kubectl get storageclass -o jsonpath='{range .items[*]}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' | grep -q true; then
  echo "WARNING: no default StorageClass. The model PVCs in step 3 name none and will sit Pending." >&2
fi

banner "Gateway API $GWAPI_VERSION, experimental channel"
kubectl apply --server-side --force-conflicts \
  -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GWAPI_VERSION}/experimental-install.yaml" >/dev/null
echo "    applied"

banner "agentgateway CRDs $AGW_VERSION"
helm_ upgrade --install agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
  --namespace "$NS" --create-namespace --version "$AGW_VERSION" --wait >/dev/null
echo "    installed"

banner "agentgateway control plane $AGW_VERSION"
helm_ upgrade --install agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --namespace "$NS" --version "$AGW_VERSION" \
  -f "$HERE/yaml/platform/10-agentgateway-values.yaml" --wait --timeout 5m >/dev/null
echo "    installed"

# The GatewayClass being Accepted is the readiness signal; a Gateway applied before it never programs.
banner "GatewayClass"
kubectl wait --for=jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'=True gatewayclass/agentgateway --timeout=180s

banner "the public Gateway"
kubectl apply -f "$HERE/yaml/platform/05-gateway.yaml"
kubectl wait --for=condition=Programmed gateway/model-gateway -n "$NS" --timeout=180s
kubectl -n "$NS" get gateway model-gateway
echo
echo "Next: ./scripts/platform/20-device-plugin.sh"
