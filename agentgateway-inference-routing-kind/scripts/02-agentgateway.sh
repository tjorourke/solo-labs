#!/usr/bin/env bash
# 02-agentgateway.sh — install agentgateway with the Inference Extension turned
# on. inferenceExtension.enabled=true is what makes the controller watch
# InferencePool and delegate endpoint selection to the GIE Endpoint Picker.
#
# Enterprise (default): Solo chart, GatewayClass enterprise-agentgateway,
# needs a license. OSS (AGW_EDITION=oss): cr.agentgateway.dev chart,
# GatewayClass agentgateway, no license.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
require_secrets

step "Installing agentgateway CRDs ($AGW_EDITION $AGW_VERSION)"
helm --kube-context "$CTX" upgrade --install agentgateway-crds "$AGW_CRDS_CHART" \
  --namespace "$AGW_NS" --create-namespace --version "$AGW_VERSION" \
  --wait --timeout 3m >/dev/null
ok "agentgateway CRDs installed"

step "Installing agentgateway control plane ($AGW_EDITION $AGW_VERSION, inference extension enabled)"
if [[ "$AGW_EDITION" == "oss" ]]; then
  helm --kube-context "$CTX" upgrade --install agentgateway "$AGW_CHART" \
    --namespace "$AGW_NS" --version "$AGW_VERSION" \
    --set inferenceExtension.enabled=true \
    --wait --timeout 5m >/dev/null
else
  helm --kube-context "$CTX" upgrade --install agentgateway "$AGW_CHART" \
    --namespace "$AGW_NS" --version "$AGW_VERSION" \
    --set licensing.licenseKey="${AGENTGATEWAY_LICENSE_KEY}" \
    --set inferenceExtension.enabled=true \
    --wait --timeout 5m >/dev/null
fi
ok "agentgateway installed — GatewayClass '$GATEWAY_CLASS'"
kc get gatewayclass "$GATEWAY_CLASS" >/dev/null 2>&1 \
  && ok "GatewayClass '$GATEWAY_CLASS' present" \
  || warn "GatewayClass '$GATEWAY_CLASS' not found yet"
