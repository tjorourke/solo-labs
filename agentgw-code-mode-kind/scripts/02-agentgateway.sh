#!/usr/bin/env bash
# 02-agentgateway.sh — install Solo Enterprise agentgateway (code-mode capable).
#
# Code mode (EnterpriseAgentgatewayBackend entMcp.toolMode: Code → the run_code
# tool + JS sandbox) ships in the CalVer line (present since v2026.5.0); the older
# SemVer 2.3.x backend has no entMcp. Pin v2026.5.2, the latest monthly.
#
# The chart is in solo-public on Google Artifact Registry; even though public,
# helm OCI pull needs an authenticated `helm registry login` (ensure_gar_auth).
# The data plane refuses to start without a license (licensing.licenseKey).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_secrets

step "Authenticating helm OCI to $AGW_GAR_HOST"
ensure_gar_auth "$AGW_GAR_HOST"
ok "helm authenticated for $AGW_GAR_HOST"

step "Installing Enterprise agentgateway CRDs $AGW_VERSION"
helm --kube-context "$CTX" upgrade --install agentgateway-crds "$AGW_CRDS_CHART" \
  --namespace "$AGW_NS" --create-namespace --version "$AGW_VERSION" --wait --timeout 3m >/dev/null
ok "CRDs installed"

step "Installing Enterprise agentgateway control plane $AGW_VERSION"
log "control-plane + ratelimit + ext-auth pods pulling — progress every 15s"
helm_install_with_progress agentgateway "$AGW_CHART" "$AGW_NS" \
  --version "$AGW_VERSION" \
  --set licensing.licenseKey="${AGENTGATEWAY_LICENSE_KEY}" \
  --wait --timeout 5m
ok "control plane installed"

step "Verifying GatewayClass registration"
if kc get gatewayclass enterprise-agentgateway >/dev/null 2>&1; then
  ok "GatewayClass enterprise-agentgateway registered"
else
  warn "GatewayClass enterprise-agentgateway not yet registered (give it a few seconds)"
fi

step "agentgateway control plane ready"
echo "  Next: ./scripts/03-backend-route.sh" >&2
