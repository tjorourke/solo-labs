#!/usr/bin/env bash
# 06-observability.sh — Prometheus + Grafana via kube-prometheus-stack,
# plus a ConfigMap with the per-team token-budget dashboard.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

step "Adding prometheus-community helm repo"
helm repo add prometheus-community "$KPS_REPO_URL" >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null
ok "repo ready"

step "Installing kube-prometheus-stack $KPS_VERSION"
log "this chart is large — cold pull is several hundred MB across multiple images"
# Pre-create the namespace so the dashboard ConfigMap (which Grafana scrapes
# via its sidecar) lands in the same place.
kc create namespace monitoring --dry-run=client -o yaml | kc apply -f - >/dev/null

# Minimal values: enable the Grafana sidecar dashboard discovery; expose
# Grafana with a fixed admin password; let alerts + node-exporter etc. ship
# with chart defaults.
log "kube-prom-stack is heavy (prometheus + grafana + node-exporter + ...) — progress every 15s below"
helm_install_with_progress monitoring "$KPS_CHART" monitoring \
  --version "$KPS_VERSION" \
  --set grafana.adminPassword=admin \
  --set grafana.sidecar.dashboards.enabled=true \
  --set grafana.sidecar.dashboards.label=grafana_dashboard \
  --set grafana.sidecar.dashboards.searchNamespace=ALL \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
  --wait --timeout 10m
ok "kube-prometheus-stack installed"

step "Applying PodMonitor + ServiceMonitor scrape config"
# Tells Prometheus to scrape the agentgateway data-plane (port 15020) and the
# rate-limit-service (port 9091). Without these the dashboard has no data,
# even though both pods expose Prometheus-format /metrics endpoints.
kc apply -f "$LAB_ROOT/yaml/observability/podmonitor.yaml" >/dev/null
ok "scrape config applied (Prometheus picks it up within ~30s; the first dashboard refresh may need to wait)"

step "Applying the per-team token budget dashboard"
kc apply -f "$LAB_ROOT/yaml/observability/dashboard-tokens.yaml" >/dev/null
ok "dashboard ConfigMap applied (will be picked up by Grafana's sidecar within ~30s)"

step "Observability ready"
echo "  Grafana:    port-forward to localhost:3000 (admin / admin)" >&2
echo "  Prometheus: port-forward to localhost:9090" >&2
echo "  Next:       ./scripts/07-agents.sh" >&2
