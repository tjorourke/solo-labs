#!/usr/bin/env bash
# gloo-ui.sh — install the Gloo UI (Solo's own dashboard for Solo Enterprise for
# Istio) so you can SEE the petshop workloads in a browser. The Gloo UI is the
# Gloo Platform management plane: on one kind cluster the mgmt server, the agent
# and the UI are co-located, and the agent relays to the mgmt server over the
# in-cluster service. Once the cluster is registered, the agent discovers the
# ambient mesh and its workloads show up under Observability.
#
# Install this BEFORE the petshop if you want to watch the workloads appear live.
# Needs GLOO_PLATFORM_LICENSE_KEY (falls back to SOLO_ISTIO_LICENSE_KEY).
#
#   ./scripts/gloo-ui.sh              # install the management plane + Gloo UI
#   ./scripts/gloo-ui.sh forward      # (re)start the background port-forward only
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require kubectl; require helm

GLOO_PLATFORM_VERSION="${GLOO_PLATFORM_VERSION:-2.12.3}"   # pairs with Istio 1.29
GLOO_MESH_NS="${GLOO_MESH_NS:-gloo-mesh}"
GLOO_PLATFORM_CHARTS="${GLOO_PLATFORM_CHARTS:-https://storage.googleapis.com/gloo-platform/helm-charts}"
GLOO_UI_URL="http://localhost:8090"
GLOO_UI_PF_LOG="/tmp/cert-identity-gloo-ui-pf.log"

# Backgrounded port-forward that does NOT hang the caller (nohup + disown), only
# started if the port isn't already serving. Logs to $GLOO_UI_PF_LOG.
forward() {
  if curl -fs -o /dev/null -m 2 "$GLOO_UI_URL" 2>/dev/null; then
    ok "Gloo UI already reachable at $GLOO_UI_URL"; return 0
  fi
  # wait for the UI pod so the forward doesn't race a not-yet-ready deployment
  kc -n "$GLOO_MESH_NS" rollout status deploy/gloo-mesh-ui --timeout=180s >/dev/null 2>&1 || true
  nohup kc -n "$GLOO_MESH_NS" port-forward svc/gloo-mesh-ui 8090:8090 >"$GLOO_UI_PF_LOG" 2>&1 &
  disown 2>/dev/null || true
  for _ in $(seq 1 30); do
    curl -fs -o /dev/null -m 2 "$GLOO_UI_URL" 2>/dev/null && { ok "Gloo UI → $GLOO_UI_URL (port-forward detached, log $GLOO_UI_PF_LOG)"; return 0; }
    sleep 1
  done
  warn "port-forward started but $GLOO_UI_URL not answering yet — check $GLOO_UI_PF_LOG"
}

install() {
  require_secrets
  local lic="${GLOO_PLATFORM_LICENSE_KEY:-${SOLO_ISTIO_LICENSE_KEY:-}}"
  [[ -n "$lic" ]] || die "GLOO_PLATFORM_LICENSE_KEY (or SOLO_ISTIO_LICENSE_KEY) not set"

  step "Installing Gloo Platform management plane + Gloo UI ($GLOO_PLATFORM_VERSION)"
  helm repo add gloo-platform "$GLOO_PLATFORM_CHARTS" >/dev/null 2>&1 || true
  helm repo update gloo-platform >/dev/null
  kc create namespace "$GLOO_MESH_NS" >/dev/null 2>&1 || true

  helm --kube-context "$CTX" upgrade --install gloo-platform-crds gloo-platform/gloo-platform-crds \
    --namespace "$GLOO_MESH_NS" --version "$GLOO_PLATFORM_VERSION" --wait --timeout 5m >/dev/null
  ok "gloo-platform CRDs installed"

  # Single-cluster values: mgmt server AND agent in one release, co-located.
  local values; values="$(mktemp)"
  cat > "$values" <<EOF
common:
  cluster: ${CLUSTER_NAME}
licensing:
  glooMeshLicenseKey: "${lic}"
glooMgmtServer:
  enabled: true
  createGlobalWorkspace: true
glooUi:
  enabled: true
  serviceType: ClusterIP
glooAgent:
  enabled: true
  relay:
    serverAddress: gloo-mesh-mgmt-server.${GLOO_MESH_NS}:9900
prometheus:
  enabled: true
redis:
  deployment:
    enabled: true
telemetryCollector:
  enabled: true
telemetryGateway:
  enabled: true
glooInsightsEngine:
  enabled: true
EOF
  helm --kube-context "$CTX" upgrade --install gloo-platform gloo-platform/gloo-platform \
    --namespace "$GLOO_MESH_NS" --version "$GLOO_PLATFORM_VERSION" -f "$values" --wait --timeout 10m >/dev/null
  rm -f "$values"

  # Register the cluster, or the co-located agent is rejected ("not registered").
  kc apply -f - >/dev/null <<EOF
apiVersion: admin.gloo.solo.io/v2
kind: KubernetesCluster
metadata:
  name: ${CLUSTER_NAME}
  namespace: ${GLOO_MESH_NS}
spec:
  clusterDomain: cluster.local
EOF
  ok "Gloo UI installed and cluster '${CLUSTER_NAME}' registered"
  forward
  log "In the UI: Observability → then the petshop namespace/workloads (deploy petshop first if you haven't)."
}

case "${1:-install}" in
  forward) forward ;;
  *)       install ;;
esac
