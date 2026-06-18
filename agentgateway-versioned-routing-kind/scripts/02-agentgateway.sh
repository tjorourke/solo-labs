#!/usr/bin/env bash
# 02-agentgateway.sh — install Solo Enterprise for agentgateway on the edge
# cluster (CRDs chart + control plane) and create the Gateway, which
# auto-provisions the agentgateway proxy. Coexists with the kgateway install
# from part 1 (separate namespace + GatewayClass). Idempotent.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_license

step "Authenticating to the chart registry ($GAR_HOST)"
ensure_gar_auth "$GAR_HOST"
ok "registry auth ready"

step "Installing enterprise-agentgateway CRDs ($AGW_VERSION)"
# The extauth.solo.io / ratelimit.solo.io CRDs are shared with kgateway. If
# part 1 (kgateway) is installed in this cluster it already owns them, and helm
# refuses to adopt CRDs another release owns. Skip the shared CRDs when they
# already exist; install them when running standalone. This lab uses neither
# entExtAuth nor entRateLimit, so skipping them changes nothing here.
crd_flags=()
if kctx "$EDGE_CTX" get crd authconfigs.extauth.solo.io >/dev/null 2>&1; then
  log "authconfigs.extauth.solo.io already present (kgateway) — skipping shared ExtAuth CRDs"
  crd_flags+=(--set installExtAuthCRDs=false)
fi
if kctx "$EDGE_CTX" get crd ratelimitconfigs.ratelimit.solo.io >/dev/null 2>&1; then
  log "ratelimitconfigs.ratelimit.solo.io already present (kgateway) — skipping shared RateLimit CRDs"
  crd_flags+=(--set installRateLimitCRDs=false)
fi
helm --kube-context "$EDGE_CTX" upgrade --install enterprise-agentgateway-crds \
  "$AGW_CRDS_CHART" --version "$AGW_VERSION" \
  --namespace "$GW_NS" --create-namespace ${crd_flags[@]+"${crd_flags[@]}"} --wait --timeout 3m >/dev/null
ok "CRDs installed"

step "Installing enterprise-agentgateway control plane ($AGW_VERSION)"
helm_install_with_progress "$EDGE_CTX" enterprise-agentgateway "$AGW_CHART" "$GW_NS" \
  --version "$AGW_VERSION" \
  --set licensing.licenseKey="$AGENTGATEWAY_LICENSE_KEY" \
  --wait --timeout 5m
ok "control plane installed"

step "Creating the Gateway (auto-provisions the agentgateway proxy)"
kctx "$EDGE_CTX" apply -f "$LAB_ROOT/yaml/edge/gateway.yaml" >/dev/null
log "waiting for the proxy deployment '$GW_NAME' to provision..."
wait_deploy "$EDGE_CTX" "$GW_NS" "$GW_NAME" 300s \
  || warn "proxy '$GW_NAME' not Available yet — check: kubectl --context $EDGE_CTX -n $GW_NS get pods"
ok "gateway '$GW_NAME' provisioned"

kctx "$EDGE_CTX" -n "$GW_NS" get gateway "$GW_NAME" 2>/dev/null | sed 's/^/  /' >&2 || true
echo "  Next: ./scripts/03-apps.sh" >&2
