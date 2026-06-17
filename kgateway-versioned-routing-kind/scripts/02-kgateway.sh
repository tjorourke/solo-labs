#!/usr/bin/env bash
# 02-kgateway.sh — install Solo Enterprise for kgateway on the edge cluster
# (CRDs chart + control-plane chart) and create the Gateway, which
# auto-provisions the Envoy proxy. Idempotent.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_license

step "Authenticating to the chart registry ($GAR_HOST)"
ensure_gar_auth "$GAR_HOST"
ok "registry auth ready"

step "Installing enterprise-kgateway CRDs ($KGW_VERSION)"
helm --kube-context "$EDGE_CTX" upgrade --install enterprise-kgateway-crds \
  "$KGW_CRDS_CHART" --version "$KGW_VERSION" \
  --namespace "$GW_NS" --create-namespace --wait --timeout 3m >/dev/null
ok "CRDs installed"

step "Installing enterprise-kgateway control plane ($KGW_VERSION)"
helm_install_with_progress "$EDGE_CTX" enterprise-kgateway "$KGW_CHART" "$GW_NS" \
  --version "$KGW_VERSION" \
  --set licensing.licenseKey="$KGATEWAY_LICENSE_KEY" \
  --wait --timeout 5m
ok "control plane installed"

log "waiting for the kgateway controller..."
wait_deploy "$EDGE_CTX" "$GW_NS" kgateway 600s 2>/dev/null \
  || kctx "$EDGE_CTX" -n "$GW_NS" rollout status deploy --timeout=300s >/dev/null 2>&1 || true
ok "controller up"

step "Creating the Gateway (auto-provisions the Envoy proxy)"
kctx "$EDGE_CTX" apply -f "$LAB_ROOT/yaml/edge/gateway.yaml" >/dev/null
log "waiting for the proxy deployment 'http' to provision..."
wait_deploy "$EDGE_CTX" "$GW_NS" http 300s || warn "proxy 'http' not Available yet — check: kubectl --context $EDGE_CTX -n $GW_NS get pods"
ok "gateway 'http' provisioned"

step "kgateway ready"
kctx "$EDGE_CTX" -n "$GW_NS" get gateway http 2>/dev/null | sed 's/^/  /' >&2 || true
echo "  Next: ./scripts/03-apps.sh" >&2
