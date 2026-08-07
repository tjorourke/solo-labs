#!/usr/bin/env bash
# consoles.sh — open the demo UIs. Run once and leave it; the port-forward is
# fully detached (nohup + disown) so it survives this shell.
#
#   Gloo UI (Solo's dashboard for Solo Enterprise for Istio) — the service
#   graph spans BOTH clusters (mgmt plane on mesh1, agents on mesh1 + mesh2).
#
# The UI has no ingress, so we port-forward svc/gloo-mesh-ui on a fixed local
# port (8091 — 8090 is often taken by other labs).
CLUSTER1="${CLUSTER1:-kind-mesh1}"
PORT="${GLOO_UI_PORT:-8091}"
GLOO_URL="http://localhost:${PORT}"

if ! curl -fs -o /dev/null -m 2 "$GLOO_URL" 2>/dev/null; then
  pkill -f "port-forward.*svc/gloo-mesh-ui ${PORT}:" 2>/dev/null || true
  nohup kubectl --context "$CLUSTER1" -n gloo-mesh \
    port-forward svc/gloo-mesh-ui "${PORT}:8090" >/tmp/ambient-demo-gloo-ui-pf.log 2>&1 &
  disown 2>/dev/null || true
  for _ in $(seq 1 20); do
    curl -fs -o /dev/null -m 2 "$GLOO_URL" 2>/dev/null && break
    sleep 1
  done
fi

# Cost Management UI (mesh1) — present only when cost management was installed
# at setup (SKIP_COST_MGMT!=true). Port-forward svc/solo-enterprise-ui.
COST_PORT="${COST_UI_PORT:-8095}"
COST_URL="http://localhost:${COST_PORT}/age/cost-management"
HAVE_COST=""
if kubectl --context "$CLUSTER1" -n solo-cost get svc solo-enterprise-ui >/dev/null 2>&1; then
  HAVE_COST=1
  if ! curl -fs -o /dev/null -m 2 "http://localhost:${COST_PORT}" 2>/dev/null; then
    pkill -f "port-forward.*svc/solo-enterprise-ui ${COST_PORT}:" 2>/dev/null || true
    nohup kubectl --context "$CLUSTER1" -n solo-cost \
      port-forward svc/solo-enterprise-ui "${COST_PORT}:80" >/tmp/ambient-demo-cost-ui-pf.log 2>&1 &
    disown 2>/dev/null || true
  fi
fi

if command -v open >/dev/null 2>&1; then
  open "$GLOO_URL" 2>/dev/null || true
  [ -n "$HAVE_COST" ] && open "$COST_URL" 2>/dev/null || true
fi

# Only advertise the Solo UI links when the UI is actually present. The same
# UI serves demo-7's views: Dashboard (live traffic per model — watch the §2
# failover move), Tracing (one span per request) and Virtual Keys.
if [ -n "$HAVE_COST" ]; then
  COST_CONSOLE_LINE="  Cost Management (mesh1)                 ${COST_URL}
  AI gateway Dashboard (demo-7)           http://localhost:${COST_PORT}/age/
  AI gateway Tracing (demo-7)             http://localhost:${COST_PORT}/age/tracing"
else
  COST_CONSOLE_LINE="  Cost Management: not installed — run ./demo-scripts/cost-mgmt.sh"
fi

cat <<EOF

  Consoles
  ────────────────────────────────────────────────────────────
  Gloo UI (service graph, BOTH clusters)   ${GLOO_URL}
${COST_CONSOLE_LINE}
  ────────────────────────────────────────────────────────────
  Graph tips for the demo:
    - tick both clusters + the bookinfo / petshop namespaces in the pickers
    - Graph Settings (gear): turn "Idle Nodes" OFF so only LIVE traffic draws
      (otherwise stale edges linger after a failover and it looks like traffic
      never came back), and set Traffic to "Last 1 min"
    - give it ~15-30s after each change for the scrape/refresh to catch up
  Port-forward log: /tmp/ambient-demo-gloo-ui-pf.log
  Stop it:          pkill -f 'port-forward.*gloo-mesh-ui'
EOF
