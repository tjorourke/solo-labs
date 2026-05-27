#!/usr/bin/env bash
# 02-agentgateway.sh — install Solo Enterprise agentgateway.
#
# Enterprise (not OSS) because:
#   - ratelimit.solo.io/v1alpha1 RateLimitConfig
#   - EnterpriseAgentgatewayPolicy.traffic.entRateLimit (TOKEN-type LLM
#     counters)
#   - the bundled enterprise rate-limit server
# all ship only with the Enterprise CRDs + control-plane charts.
#
# Chart is hosted in solo-public on Google Artifact Registry. Even though the
# repo is public, helm OCI pull returns 401 without `helm registry login`
# using a gcloud access token. ensure_gar_auth() runs the whole dance and is
# idempotent. The data plane also refuses to start without a valid licenseKey
# (passed via --set licensing.licenseKey=...).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_secrets

step "Authenticating helm OCI to $AGW_GAR_HOST"
ensure_gar_auth "$AGW_GAR_HOST"
ok "gcloud + docker + helm authenticated for $AGW_GAR_HOST"

# Clean up release names from prior failed runs of an earlier version of this
# script (which used `enterprise-agentgateway-crds` / `enterprise-agentgateway`).
# We now match the proven sibling labs' pattern.
for old in enterprise-agentgateway enterprise-agentgateway-crds; do
  if helm --kube-context "$CTX" -n agentgateway-system status "$old" >/dev/null 2>&1; then
    log "removing stale helm release $old (from a prior failed run)"
    helm --kube-context "$CTX" -n agentgateway-system uninstall "$old" --no-hooks >/dev/null 2>&1 || true
  fi
done

step "Installing Enterprise agentgateway CRDs $AGW_VERSION"
log "chart: $AGW_CRDS_CHART"
helm --kube-context "$CTX" upgrade --install agentgateway-crds "$AGW_CRDS_CHART" \
  --namespace agentgateway-system --create-namespace \
  --version "$AGW_VERSION" \
  --wait --timeout 3m >/dev/null
ok "CRDs installed"

step "Installing Enterprise agentgateway control plane $AGW_VERSION"
log "chart: $AGW_CHART"
log "control-plane + ratelimit + ext-auth pods pulling — progress every 15s below"
# Helm value path is `licensing.licenseKey` on the v2.3.x chart. Wrong names
# fail with "License key must be provided: .Values.licensing.licenseKey".
helm_install_with_progress agentgateway "$AGW_CHART" agentgateway-system \
  --version "$AGW_VERSION" \
  --set licensing.licenseKey="${AGENTGATEWAY_LICENSE_KEY}" \
  --wait --timeout 5m
ok "control plane installed"

step "Verifying GatewayClass registration"
# Enterprise registers `enterprise-agentgateway` (the OSS chart uses
# `agentgateway`). The Gateway resource in yaml/agentgateway/gateway.yaml
# MUST reference the enterprise class name.
if kc get gatewayclass enterprise-agentgateway >/dev/null 2>&1; then
  ok "GatewayClass enterprise-agentgateway registered"
else
  warn "GatewayClass enterprise-agentgateway not yet registered (may need a few more seconds)"
fi

step "Enterprise agentgateway ready"
echo "  Next: ./scripts/03-kagent.sh" >&2
