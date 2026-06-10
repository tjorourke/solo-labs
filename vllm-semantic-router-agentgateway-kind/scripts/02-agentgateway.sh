#!/usr/bin/env bash
# 02-agentgateway.sh — install OSS upstream agentgateway (cr.agentgateway.dev).
#
# OSS upstream (not Solo Enterprise) because this lab needs ExtProc body-mode
# control: the vLLM Semantic Router buffers and rewrites the request body, which
# requires processingOptions.allowModeOverride on the ExtProc policy. Only the
# upstream agentgateway exposes that. The charts pull anonymously — no license,
# no registry auth.
#
# KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true is set because ExtProc rides
# on the Gateway API experimental features.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

step "Installing agentgateway CRDs $AGW_VERSION"
helm --kube-context "$CTX" upgrade --install agentgateway-crds "$AGW_CRDS_CHART" \
  --namespace agentgateway-system --create-namespace \
  --version "$AGW_VERSION" \
  --set controller.image.pullPolicy=Always \
  --wait --timeout 3m >/dev/null
ok "CRDs installed"

step "Installing agentgateway control plane $AGW_VERSION"
log "controller pod pulling — progress every 15s below"
helm_install_with_progress agentgateway "$AGW_CHART" agentgateway-system \
  --version "$AGW_VERSION" \
  --set controller.image.pullPolicy=Always \
  --set controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true \
  --wait --timeout 5m
ok "control plane installed"

step "Verifying GatewayClass registration"
if kc get gatewayclass agentgateway >/dev/null 2>&1; then
  ok "GatewayClass agentgateway registered"
else
  warn "GatewayClass agentgateway not yet registered (may need a few more seconds)"
fi

step "agentgateway control plane ready"
echo "  Next: ./scripts/03-vllm-backend.sh" >&2
