#!/usr/bin/env bash
# 02-agentgateway.sh — install Solo Enterprise agentgateway.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

if [[ "$EDITION" == "oss" ]]; then
  # Upstream agentgateway: public OCI charts, no registry auth, no license.
  step "Installing agentgateway OSS CRDs $AGW_OSS_VERSION"
  helm --kube-context "$CTX" upgrade --install agentgateway-crds \
    "${AGW_OSS_REGISTRY}/agentgateway-crds" \
    --namespace "$AGW_NS" --create-namespace --version "$AGW_OSS_VERSION" \
    --wait --timeout 3m >/dev/null
  ok "CRDs installed"

  step "Installing agentgateway OSS control plane $AGW_OSS_VERSION"
  helm_install_with_progress agentgateway "${AGW_OSS_REGISTRY}/agentgateway" "$AGW_NS" \
    --version "$AGW_OSS_VERSION" --wait --timeout 5m
  ok "control plane installed"

  kc get gatewayclass agentgateway >/dev/null 2>&1 \
    && ok "GatewayClass agentgateway registered" \
    || warn "GatewayClass agentgateway not yet registered"

  step "agentgateway OSS installed"
  echo "  Next: ./scripts/03-pki.sh" >&2
  exit 0
fi

require_secrets

step "Authenticating helm OCI to $AGW_GAR_HOST"
ensure_gar_auth "$AGW_GAR_HOST"
ok "helm authenticated for $AGW_GAR_HOST"

step "Installing Enterprise agentgateway CRDs $AGW_VERSION"
helm --kube-context "$CTX" upgrade --install agentgateway-crds "$AGW_CRDS_CHART" \
  --namespace "$AGW_NS" --create-namespace --version "$AGW_VERSION" --wait --timeout 3m >/dev/null
ok "CRDs installed"

step "Installing Enterprise agentgateway control plane $AGW_VERSION"
log "control-plane pods pulling — progress every 15s"
helm_install_with_progress agentgateway "$AGW_CHART" "$AGW_NS" \
  --version "$AGW_VERSION" \
  --set licensing.licenseKey="${AGENTGATEWAY_LICENSE_KEY}" \
  --wait --timeout 5m
ok "control plane installed"

kc get gatewayclass enterprise-agentgateway >/dev/null 2>&1 \
  && ok "GatewayClass enterprise-agentgateway registered" \
  || warn "GatewayClass not yet registered"

step "agentgateway installed"
echo "  Next: ./scripts/03-pki.sh" >&2
