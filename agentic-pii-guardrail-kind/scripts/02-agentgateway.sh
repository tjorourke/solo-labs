#!/usr/bin/env bash
# 02-agentgateway.sh — install Solo Enterprise agentgateway.
#
# Enterprise (not OSS) because promptGuard — the field that ships built-in
# regex masks plus the webhook backendRef — lives on EnterpriseAgentgatewayPolicy.
# The OSS AgentgatewayPolicy schema has no promptGuard. See CLAUDE.md.
#
# Chart is hosted in solo-public on Google Artifact Registry. Even though the
# repo is public, helm OCI pull returns 401 without `helm registry login`
# using a gcloud access token. ensure_gar_auth() runs the whole dance and is
# idempotent on re-runs. The data plane also refuses to start without a valid
# licenseKey (passed via --set licenseKey=...).

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
# Helm value path is `licensing.licenseKey` (not `licenseKey`) on the v2.3.x chart.
helm_install_with_progress agentgateway "$AGW_CHART" agentgateway-system \
  --version "$AGW_VERSION" \
  --set licensing.licenseKey="${AGENTGATEWAY_LICENSE_KEY}" \
  --wait --timeout 5m
ok "control plane installed"

step "Verifying GatewayClass registration"
# The enterprise chart registers two classes: north-south + waypoint. We use
# the north-south one (enterprise-agentgateway) in this lab.
if kc get gatewayclass enterprise-agentgateway >/dev/null 2>&1; then
  ok "GatewayClass enterprise-agentgateway registered"
else
  warn "GatewayClass enterprise-agentgateway not yet registered (may need a few more seconds)"
fi

step "agentgateway control plane ready"
echo "  Next: ./scripts/03-guardrail-and-ui.sh" >&2
