#!/usr/bin/env bash
# 02-agentgateway.sh — install OSS agentgateway.
#
# OSS chart at oci://cr.agentgateway.dev — public, anonymous helm pull works.
# No license key, no gcloud auth required.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_secrets

step "Installing OSS agentgateway CRDs $AGW_VERSION"
helm --kube-context "$CTX" upgrade --install agentgateway-crds "$AGW_CRDS_CHART" \
  --namespace agentgateway-system --create-namespace \
  --version "$AGW_VERSION" \
  --wait --timeout 3m >/dev/null
ok "CRDs installed"

step "Installing OSS agentgateway control plane $AGW_VERSION"
log "control-plane pod pulling — progress every 15s below"
helm_install_with_progress agentgateway "$AGW_CHART" agentgateway-system \
  --version "$AGW_VERSION" \
  --wait --timeout 5m
ok "control plane installed"

step "Verifying GatewayClass registration"
if kc get gatewayclass agentgateway >/dev/null 2>&1; then
  ok "GatewayClass agentgateway registered"
else
  warn "GatewayClass agentgateway not yet registered (may need a few more seconds)"
fi

step "agentgateway control plane ready"
echo "  Next: ./scripts/03-kagent.sh" >&2
