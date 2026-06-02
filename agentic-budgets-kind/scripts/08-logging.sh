#!/usr/bin/env bash
# 08-logging.sh — per-user token visibility via access logs.
#
#   1. loki-stack (Loki + Promtail) into the monitoring ns. Promtail scrapes
#      every pod's stdout, including the gateway access log.
#   2. The access-log attribution policy — stamps each LLM access-log line
#      with user_id (jwt.sub) + the llm.* token counts.
#   3. A Loki datasource for the kube-prometheus-stack Grafana, plus the
#      dashboard (re-applied) which now carries the per-user log panels.
#
# Budgets are per team; this step adds the per-user visibility layer.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

step "Adding grafana helm repo"
helm repo add grafana "$LOKI_REPO_URL" >/dev/null 2>&1 || true
helm repo update grafana >/dev/null
ok "repo ready"

step "Installing loki-stack $LOKI_VERSION (Loki + Promtail)"
log "Grafana + Prometheus subcharts disabled — we reuse kube-prometheus-stack's Grafana"
helm_install_with_progress loki "$LOKI_CHART" monitoring \
  --version "$LOKI_VERSION" \
  --set loki.enabled=true \
  --set promtail.enabled=true \
  --set grafana.enabled=false \
  --set prometheus.enabled=false \
  --wait --timeout 10m
ok "loki-stack installed"

step "Applying access-log token-attribution policy"
kc apply -f "$LAB_ROOT/yaml/agentgateway/accesslog-policy.yaml" >/dev/null
ok "attribution policy applied (gateway stamps user_id + token counts on the access log)"

step "Registering Loki as a Grafana datasource"
# loki-stack ships its own 'Loki' datasource ConfigMap with no uid and
# isDefault:true. It collides (same name) with ours, which breaks Grafana
# datasource provisioning (all datasources fail to load). Remove the chart's
# copy and keep ours, which pins uid:loki — the uid the dashboard panels use.
kc delete configmap loki-loki-stack -n monitoring --ignore-not-found >/dev/null 2>&1 || true
kc apply -f "$LAB_ROOT/yaml/observability/loki-datasource.yaml" >/dev/null
ok "Loki datasource ConfigMap applied (uid:loki; Grafana sidecar loads it within ~30s)"

step "Re-applying the token dashboard (now with per-user log panels)"
kc apply -f "$LAB_ROOT/yaml/observability/dashboard-tokens.yaml" >/dev/null
ok "dashboard updated"

step "Logging ready"
echo "  Grafana: port-forward to localhost:3000 (admin / admin)" >&2
echo "  Open 'Per-Team LLM Token Budgets' — the per-user log panels are at the bottom" >&2
