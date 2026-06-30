#!/usr/bin/env bash
# 02-agentgateway.sh — install Solo Enterprise agentgateway (needs license +
# gcloud-authed helm OCI pull). Same as the guardrail labs.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
require_secrets

step "Authenticating helm OCI to $AGW_GAR_HOST"
ensure_gar_auth "$AGW_GAR_HOST"; ok "authenticated"

step "Installing Enterprise agentgateway CRDs $AGW_VERSION"
helm --kube-context "$CTX" upgrade --install agentgateway-crds "$AGW_CRDS_CHART" \
  --namespace agentgateway-system --create-namespace --version "$AGW_VERSION" --wait --timeout 3m >/dev/null
ok "CRDs installed"

step "Installing Enterprise agentgateway control plane $AGW_VERSION"
helm_install_with_progress agentgateway "$AGW_CHART" agentgateway-system \
  --version "$AGW_VERSION" --set licensing.licenseKey="${AGENTGATEWAY_LICENSE_KEY}" --wait --timeout 5m
ok "control plane installed"

if kc get gatewayclass enterprise-agentgateway >/dev/null 2>&1; then
  ok "GatewayClass enterprise-agentgateway registered"
else
  warn "GatewayClass not yet registered (may need a few more seconds)"
fi
step "agentgateway ready"
echo "  Next: ./scripts/03-deploy.sh" >&2
