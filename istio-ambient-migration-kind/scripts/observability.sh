#!/usr/bin/env bash
# observability.sh — stand up the two UIs the guide shows in its per-step tabs:
#
#   1. The Gloo UI (Solo's own management dashboard for Solo Enterprise for
#      Istio). This is the Gloo Platform management plane — mgmt server + agent +
#      Gloo UI + its Prometheus/telemetry pipeline — layered onto the same kind
#      cluster. Single cluster, so the mgmt server and the agent are co-located
#      and the agent relays to the mgmt server over the in-cluster service.
#      Reached with `meshctl dashboard` (Observability -> Graph).
#
#   2. Kiali, pointed at the Gloo Platform Prometheus. On the Solo distribution
#      ztunnel emits L7 metrics with no waypoint, so Kiali shows an HTTP graph
#      (response codes) even in the L4-only petstore-data namespace.
#
# The Gloo UI half needs its own licence: GLOO_PLATFORM_LICENSE_KEY (falls back
# to SOLO_ISTIO_LICENSE_KEY if the same key is valid for both). If neither is
# set, the Gloo UI is skipped with a warning and only Kiali is installed.
#
# NOTE: this script is a first cut and has not yet been validated end-to-end on
# this lab's Gloo-Operator-managed istiod. The uncertain part is getting the
# Graph to populate — the Gloo telemetry pipeline must scrape the mesh metrics.
# Run it, watch the pods, and we iterate on the telemetry wiring.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require kubectl; require helm

GLOO_PLATFORM_VERSION="${GLOO_PLATFORM_VERSION:-2.12.3}"
GLOO_MESH_NS="${GLOO_MESH_NS:-gloo-mesh}"
KIALI_VERSION="${KIALI_VERSION:-}"   # empty = latest from the kiali helm repo
GLOO_PLATFORM_CHARTS="${GLOO_PLATFORM_CHARTS:-https://storage.googleapis.com/gloo-platform/helm-charts}"

# ── 1. Gloo Platform management plane + Gloo UI ─────────────────────────────────
install_gloo_ui() {
  load_secrets
  local lic="${GLOO_PLATFORM_LICENSE_KEY:-${SOLO_ISTIO_LICENSE_KEY:-}}"
  if [[ -z "$lic" ]]; then
    warn "GLOO_PLATFORM_LICENSE_KEY not set — skipping the Gloo UI (management plane). Kiali will still install."
    return 1
  fi

  step "Installing the Gloo Platform management plane + Gloo UI ($GLOO_PLATFORM_VERSION)"
  helm repo add gloo-platform "$GLOO_PLATFORM_CHARTS" >/dev/null 2>&1 || true
  helm repo update gloo-platform >/dev/null

  kc create namespace "$GLOO_MESH_NS" >/dev/null 2>&1 || true

  helm --kube-context "$CTX" upgrade --install gloo-platform-crds gloo-platform/gloo-platform-crds \
    --namespace "$GLOO_MESH_NS" --version "$GLOO_PLATFORM_VERSION" \
    --wait --timeout 5m >/dev/null
  ok "gloo-platform CRDs installed"

  # Single-cluster values: mgmt server AND agent in one release, co-located.
  # The agent relays to the mgmt server over the in-cluster ClusterIP service,
  # so no NodePort relay is needed (unlike the multi-cluster rugpull demo).
  local values; values="$(mktemp)"
  cat > "$values" <<EOF
common:
  cluster: ${CLUSTER_NAME}
licensing:
  glooMeshLicenseKey: "${lic}"
glooMgmtServer:
  enabled: true
  createGlobalWorkspace: true
  ports:
    healthcheck: 8091
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
    --namespace "$GLOO_MESH_NS" --version "$GLOO_PLATFORM_VERSION" \
    -f "$values" --wait --timeout 10m >/dev/null
  rm -f "$values"

  # Register this cluster with the mgmt server, or the co-located agent is
  # rejected with "cluster <name> is not registered".
  kc apply -f - >/dev/null <<EOF
apiVersion: admin.gloo.solo.io/v2
kind: KubernetesCluster
metadata:
  name: ${CLUSTER_NAME}
  namespace: ${GLOO_MESH_NS}
spec:
  clusterDomain: cluster.local
EOF

  ok "Gloo UI installed. Open it with: meshctl dashboard --kubecontext $CTX"
  log "  (or: kubectl -n $GLOO_MESH_NS port-forward deploy/gloo-mesh-ui 8090, then http://localhost:8090)"
  log "  In the UI: Observability -> Graph -> cluster '$CLUSTER_NAME', namespace 'petstore'."
  return 0
}

# ── 2. Kiali (points at the Gloo Platform Prometheus) ───────────────────────────
install_kiali() {
  step "Installing Kiali in $ISTIO_SYSTEM_NS"
  helm repo add kiali https://kiali.org/helm-charts >/dev/null 2>&1 || true
  helm repo update kiali >/dev/null

  local ver_args=()
  [[ -n "$KIALI_VERSION" ]] && ver_args=(--version "$KIALI_VERSION")

  # Prometheus: reuse the Gloo Platform one if the management plane is up,
  # otherwise fall back to the conventional in-mesh prometheus service name.
  local prom_url="http://prometheus.${GLOO_MESH_NS}:9090"
  if ! kc -n "$GLOO_MESH_NS" get svc prometheus >/dev/null 2>&1; then
    prom_url="http://prometheus.${ISTIO_SYSTEM_NS}:9090"
    warn "Gloo Platform Prometheus not found — pointing Kiali at $prom_url (install a Prometheus that scrapes istio if this is empty)."
  fi

  helm --kube-context "$CTX" upgrade --install kiali-server kiali/kiali-server \
    --namespace "$ISTIO_SYSTEM_NS" "${ver_args[@]}" \
    --set auth.strategy=anonymous \
    --set deployment.ingress.enabled=false \
    --set "external_services.prometheus.url=${prom_url}" \
    --set external_services.istio.root_namespace="$ISTIO_SYSTEM_NS" \
    --wait --timeout 5m >/dev/null

  ok "Kiali installed. Open it with:"
  log "  kubectl -n $ISTIO_SYSTEM_NS port-forward svc/kiali 20001"
  log "  then http://localhost:20001 -> Graph -> namespace 'petstore' (or 'petstore-data')."
}

main() {
  require_secrets
  install_gloo_ui || true   # non-fatal: keep Kiali even if the Gloo UI is skipped
  install_kiali
  echo
  ok "Observability layer ready. The guide's per-step Gloo UI / Kiali tabs describe what to capture at each step."
}

main "$@"
