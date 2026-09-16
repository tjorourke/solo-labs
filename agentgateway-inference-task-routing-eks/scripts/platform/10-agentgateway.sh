#!/usr/bin/env bash
# Platform step 1: Solo Enterprise for agentgateway, set up as an inference gateway that
# classifies, and the Enterprise UI that reports on it.
#
#   ./scripts/platform/10-agentgateway.sh
#
# Five things, in this order:
#   1. the Gateway API standard CRDs. Gateway and HTTPRoute come from upstream in both
#      editions; everything else this lab uses is a Solo CRD.
#   2. the Enterprise CRDs chart.
#   3. the Enterprise control plane, with the licence key and the cost dimensions in
#      yaml/platform/11-dimensions-values.yaml.
#   4. the management chart, which is the Enterprise UI, its collector and its store.
#   5. the Gateway itself, ClusterIP, which the controller turns into a data-plane
#      Deployment.
#
# The OSS conversion of every manifest is in yaml-oss/, and the routing in this lab runs
# unchanged on it. What the Enterprise edition adds here is the UI: per-user token usage and
# spend, sliced by the decisions this flow makes.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$HERE/scripts/lib.sh"
GWAPI_VERSION="${GWAPI_VERSION:-v1.6.1}"
AGW_VERSION="${AGW_ENT_VERSION:-v2026.9.0}"
MGMT_VERSION="${MGMT_VERSION:-0.5.7}"
ENT_CHART=oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts
MGMT_CHART=oci://us-docker.pkg.dev/solo-public/solo-enterprise-helm/charts/management

[ -n "${AGENTGATEWAY_LICENSE_KEY:-}" ] || {
  echo "ERROR: AGENTGATEWAY_LICENSE_KEY is not set. Solo Enterprise needs a licence key." >&2
  echo "       The OSS conversion in yaml-oss/ needs none; see the lab page." >&2
  exit 1
}

banner "the cluster this is going onto"
kubectl get nodes -o custom-columns='NODE:.metadata.name,READY:.status.conditions[-1].status,GPU:.status.allocatable.nvidia\.com/gpu,ROLE:.metadata.labels.role'
if ! kubectl get storageclass -o jsonpath='{range .items[*]}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' | grep -q true; then
  echo "WARNING: no default StorageClass. The model PVCs in step 3 name none and will sit Pending." >&2
fi

banner "Gateway API $GWAPI_VERSION"
kubectl apply --server-side --force-conflicts \
  -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GWAPI_VERSION}/experimental-install.yaml" >/dev/null
echo "    applied"

banner "Enterprise agentgateway CRDs $AGW_VERSION"
helm_ upgrade --install enterprise-agentgateway-crds "$ENT_CHART/enterprise-agentgateway-crds" \
  --namespace "$NS" --create-namespace --version "$AGW_VERSION" --wait --timeout 5m >/dev/null
echo "    installed"

banner "Enterprise agentgateway control plane $AGW_VERSION"
helm_ upgrade --install enterprise-agentgateway "$ENT_CHART/enterprise-agentgateway" \
  --namespace "$NS" --version "$AGW_VERSION" \
  --set-string licensing.licenseKey="$AGENTGATEWAY_LICENSE_KEY" \
  -f "$HERE/yaml/platform/11-dimensions-values.yaml" --wait --timeout 10m >/dev/null
echo "    installed, with the cost dimensions from yaml/platform/11-dimensions-values.yaml"

banner "the Enterprise UI $MGMT_VERSION"
helm_ upgrade --install management "$MGMT_CHART" \
  --namespace "$NS" --version "$MGMT_VERSION" \
  --set cluster="${UI_CLUSTER_NAME:-model-routing}" \
  --set products.agentgateway.enabled=true \
  --set products.agentgateway.features.cost-management=true \
  --set-string licensing.licenseKey="$AGENTGATEWAY_LICENSE_KEY" \
  --wait --timeout 15m >/dev/null
echo "    installed. Reach it with:"
echo "    kubectl -n $NS port-forward svc/solo-enterprise-ui 4000:80   then http://localhost:4000/age/"

# The GatewayClass being Accepted is the readiness signal; a Gateway applied before it never programs.
banner "GatewayClass"
kubectl wait --for=jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'=True gatewayclass/enterprise-agentgateway --timeout=180s

banner "the public Gateway"
kubectl apply -f "$HERE/yaml/platform/05-gateway.yaml"
kubectl wait --for=condition=Programmed gateway/model-gateway -n "$NS" --timeout=180s
kubectl -n "$NS" get gateway model-gateway
echo
echo "Next: ./scripts/platform/20-device-plugin.sh"
