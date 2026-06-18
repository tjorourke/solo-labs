#!/usr/bin/env bash
# 02-agentgateway.sh — install Solo Enterprise for agentgateway (CRDs chart +
# control plane) and create the Gateway, which auto-provisions the proxy.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib.sh"

require_license

step "Authenticating to the chart registry ($GAR_HOST)"
ensure_gar_auth "$GAR_HOST"; ok "registry auth ready"

step "Installing enterprise-agentgateway CRDs ($AGW_VERSION)"
helm --kube-context "$CTX" upgrade --install enterprise-agentgateway-crds \
  "$AGW_CRDS_CHART" --version "$AGW_VERSION" \
  --namespace "$GW_NS" --create-namespace --wait --timeout 3m >/dev/null
ok "CRDs installed"

step "Installing enterprise-agentgateway control plane ($AGW_VERSION)"
helm_install_with_progress enterprise-agentgateway "$AGW_CHART" "$GW_NS" \
  --version "$AGW_VERSION" \
  --set licensing.licenseKey="$AGENTGATEWAY_LICENSE_KEY" \
  --wait --timeout 5m
ok "control plane installed"

step "Creating the Gateway (auto-provisions the agentgateway proxy)"
kctx apply -f "$LAB_ROOT/yaml/gateway.yaml" >/dev/null
log "waiting for the proxy deployment '$GW_NAME' to provision..."
wait_deploy "$GW_NS" "$GW_NAME" 300s \
  || warn "proxy '$GW_NAME' not Available yet — check: kubectl --context $CTX -n $GW_NS get pods"
ok "gateway '$GW_NAME' provisioned"
echo "  Next: ./scripts/03-aws-profiles.sh" >&2
