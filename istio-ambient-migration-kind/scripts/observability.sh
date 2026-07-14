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

# ── 2. Kiali + its own istio-scoped Prometheus ──────────────────────────────────
# Kiali needs a Prometheus that scrapes the istio proxies the standard way — the
# Gloo Platform Prometheus does NOT serve Kiali's graph queries. Two extra fixes
# are needed for Kiali's traffic graph to populate on the Solo ambient mesh:
#   1. istiod CLUSTER_ID must equal the metric `cluster` label — set via the
#      ServiceMeshController `spec.cluster` (see yaml/00-mesh/smc-*.yaml). Kiali
#      reads it as its home cluster; a mismatch filters out every metric.
#   2. Solo ambient telemetry emits `destination_service` (FQDN) but not the
#      `destination_service_name` / `destination_service_namespace` labels Kiali
#      groups on. We synthesise them from the FQDN with metric_relabel_configs.
ISTIO_PROM_RELEASE="${ISTIO_PROM_RELEASE:-1.26}"

install_istio_prometheus() {
  step "Installing an istio-scoped Prometheus for Kiali in $ISTIO_SYSTEM_NS"
  local y; y="$(mktemp)"
  curl -fsSL "https://raw.githubusercontent.com/istio/istio/release-${ISTIO_PROM_RELEASE}/samples/addons/prometheus.yaml" -o "$y" \
    || die "could not download the istio prometheus addon"
  kc apply -f "$y" >/dev/null
  rm -f "$y"

  # Synthesise destination_service_name / destination_service_namespace from the
  # destination_service FQDN on the pod-scraping jobs, so Kiali can build nodes.
  local cfg new; cfg="$(mktemp)"; new="$(mktemp)"
  kc -n "$ISTIO_SYSTEM_NS" get cm prometheus -o jsonpath='{.data.prometheus\.yml}' > "$cfg"
  python3 - "$cfg" "$new" <<'PY'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
mrc = [
  {'source_labels': ['destination_service'], 'regex': r'([^.]+)\..*',
   'target_label': 'destination_service_name', 'replacement': '$1'},
  {'source_labels': ['destination_service'], 'regex': r'[^.]+\.([^.]+)\..*',
   'target_label': 'destination_service_namespace', 'replacement': '$1'},
]
for job in cfg.get('scrape_configs', []):
    if job.get('job_name') in ('kubernetes-pods', 'kubernetes-pods-slow'):
        job.setdefault('metric_relabel_configs', [])
        have = [m.get('target_label') for m in job['metric_relabel_configs']]
        for m in mrc:
            if m['target_label'] not in have:
                job['metric_relabel_configs'].append(m)
yaml.safe_dump(cfg, open(sys.argv[2], 'w'), default_flow_style=False, sort_keys=False)
PY
  kc -n "$ISTIO_SYSTEM_NS" create cm prometheus --from-file=prometheus.yml="$new" \
    --dry-run=client -o yaml | kc apply -f - >/dev/null
  rm -f "$cfg" "$new"
  kc -n "$ISTIO_SYSTEM_NS" rollout restart deploy/prometheus >/dev/null
  kc -n "$ISTIO_SYSTEM_NS" rollout status deploy/prometheus --timeout=120s >/dev/null
  ok "istio Prometheus ready (with Kiali service-label relabel)"
}

install_kiali() {
  install_istio_prometheus
  step "Installing Kiali in $ISTIO_SYSTEM_NS"
  helm repo add kiali https://kiali.org/helm-charts >/dev/null 2>&1 || true
  helm repo update kiali >/dev/null

  local ver_args=()
  [[ -n "$KIALI_VERSION" ]] && ver_args=(--version "$KIALI_VERSION")

  helm --kube-context "$CTX" upgrade --install kiali-server kiali/kiali-server \
    --namespace "$ISTIO_SYSTEM_NS" ${ver_args[@]+"${ver_args[@]}"} \
    --set auth.strategy=anonymous \
    --set deployment.ingress.enabled=false \
    --set "external_services.prometheus.url=http://prometheus.${ISTIO_SYSTEM_NS}:9090" \
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
