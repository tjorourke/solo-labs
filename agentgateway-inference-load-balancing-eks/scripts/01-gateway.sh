#!/usr/bin/env bash
# Install the Gateway API and agentgateway, with the Inference Extension turned on.
#
#   ./scripts/01-gateway.sh
#
# inferenceExtension.enabled=true is the flag that matters. Without it the controller
# does not watch InferencePool at all, so the route in yaml/11 binds to a backend it
# cannot resolve and every request 500s. Nothing on the Gateway says why.
#
# The STANDARD Gateway API channel is enough here, unlike the model-routing lab next
# door: that one needs the experimental channel for ExtProc policies, and this one does
# not use them. The Endpoint Picker is reached over ExtProc too, but the gateway wires
# that itself from the InferencePool, not from a Gateway API policy object.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require kubectl; require helm; require aws
require_secrets
resolve_ctx

step "default StorageClass"
# eksctl marks no default class and the in-tree gp2 it leaves behind is not default
# either. Anything that does not name a class then sits Pending on "no storage class is
# set", which reads as a scheduling problem rather than a missing default.
kc apply -f "$LAB_ROOT/yaml/00-storageclass.yaml" >/dev/null
ok "gp3-fast is the default StorageClass"

step "Gateway API $GATEWAY_API_VERSION (standard channel)"
# --server-side because the CRDs carry annotations that blow past the 256KB client-side
# apply limit on re-apply ("metadata.annotations: Too long").
kc apply --server-side --force-conflicts \
  -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" >/dev/null
ok "Gateway API installed"

step "Gateway API Inference Extension CRDs $GIE_VERSION"
# InferencePool (v1) and InferenceObjective (v1alpha2) come from here. The Helm chart in
# 03-pool.sh creates the objects; it does not install their CRDs.
kc apply --server-side --force-conflicts \
  -f "https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/${GIE_VERSION}/manifests.yaml" >/dev/null
ok "InferencePool and InferenceObjective CRDs installed"

step "agentgateway CRDs ($AGW_EDITION $AGW_VERSION)"
helm_ upgrade --install agentgateway-crds "$AGW_CRDS_CHART" \
  --namespace "$AGW_NS" --create-namespace --version "$AGW_VERSION" \
  --wait --timeout 3m >/dev/null
ok "installed"

step "agentgateway control plane ($AGW_EDITION $AGW_VERSION, inference extension enabled)"
if [[ "$AGW_EDITION" == "enterprise" ]]; then
  helm_ upgrade --install agentgateway "$AGW_CHART" \
    --namespace "$AGW_NS" --version "$AGW_VERSION" \
    --set licensing.licenseKey="${AGENTGATEWAY_LICENSE_KEY}" \
    --set inferenceExtension.enabled=true \
    --wait --timeout 5m >/dev/null
else
  helm_ upgrade --install agentgateway "$AGW_CHART" \
    --namespace "$AGW_NS" --version "$AGW_VERSION" \
    --set inferenceExtension.enabled=true \
    --wait --timeout 5m >/dev/null
fi
ok "installed"

# The GatewayClass being Accepted is the real readiness signal. A control plane that is
# Running but whose class is not Accepted yet produces a Gateway that never programs,
# and the Gateway's own status stays empty rather than saying so.
step "waiting for GatewayClass '$GATEWAY_CLASS'"
kc wait --for=jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'=True \
  "gatewayclass/$GATEWAY_CLASS" --timeout=180s >/dev/null
ok "GatewayClass Accepted"

kc get gatewayclass
