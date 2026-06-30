#!/usr/bin/env bash
# 02-agentgateway.sh — install Solo Enterprise agentgateway.
#
# Identical to Part 1. Enterprise (not OSS) because promptGuard — the field
# that carries the webhook backendRef — lives on EnterpriseAgentgatewayPolicy.
# (The OSS AgentgatewayPolicy now also exposes promptGuard; see yaml-oss/.)
#
# Chart is in solo-public on Google Artifact Registry; helm OCI pull returns
# 401 without `helm registry login`. ensure_gar_auth() runs the dance. The
# data plane refuses to start without a valid licenseKey.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_secrets

step "Authenticating helm OCI to $AGW_GAR_HOST"
ensure_gar_auth "$AGW_GAR_HOST"
ok "gcloud + docker + helm authenticated for $AGW_GAR_HOST"

step "Installing Enterprise agentgateway CRDs $AGW_VERSION"
helm --kube-context "$CTX" upgrade --install agentgateway-crds "$AGW_CRDS_CHART" \
  --namespace agentgateway-system --create-namespace \
  --version "$AGW_VERSION" \
  --wait --timeout 3m >/dev/null
ok "CRDs installed"

step "Installing Enterprise agentgateway control plane $AGW_VERSION"
log "control-plane + ratelimit + ext-auth pods pulling — progress every 15s below"
helm_install_with_progress agentgateway "$AGW_CHART" agentgateway-system \
  --version "$AGW_VERSION" \
  --set licensing.licenseKey="${AGENTGATEWAY_LICENSE_KEY}" \
  --wait --timeout 5m
ok "control plane installed"

step "Verifying GatewayClass registration"
if kc get gatewayclass enterprise-agentgateway >/dev/null 2>&1; then
  ok "GatewayClass enterprise-agentgateway registered"
else
  warn "GatewayClass enterprise-agentgateway not yet registered (may need a few more seconds)"
fi

step "agentgateway control plane ready"
echo "  Next: ./scripts/03-guardrail.sh" >&2
