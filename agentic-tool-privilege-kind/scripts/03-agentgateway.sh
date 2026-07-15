#!/usr/bin/env bash
# 03-agentgateway.sh — install enterprise agentgateway. It is the policy
# enforcement point: it validates the kagent OBO token and is where the
# AccessPolicy / access-log attribution that SHOWS the exchanged token live.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_secrets

step "Authenticating to the Solo chart registry"
ensure_gar_auth "$GAR_HOST"; ok "helm registry login ok ($GAR_HOST)"

step "Installing enterprise agentgateway CRDs $AGW_VERSION"
helm --kube-context "$CTX" upgrade --install agentgateway-crds "$AGW_CRDS_CHART" \
  --namespace agentgateway-system --create-namespace --version "$AGW_VERSION" --wait --timeout 3m >/dev/null
ok "agentgateway CRDs installed"

step "Installing enterprise agentgateway $AGW_VERSION"
log "image pulls + license validation can take a few min"
helm_install_with_progress agentgateway "$AGW_CHART" agentgateway-system \
  --version "$AGW_VERSION" \
  --set licensing.licenseKey="${AGENTGATEWAY_LICENSE_KEY}" \
  --wait --timeout 6m
ok "enterprise agentgateway installed"

step "agentgateway ready"; echo "  Next: ./scripts/04-kagent.sh" >&2
