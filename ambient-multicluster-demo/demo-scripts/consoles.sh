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

if command -v open >/dev/null 2>&1; then
  open "$GLOO_URL" 2>/dev/null || true
fi

cat <<EOF

  Consoles
  ────────────────────────────────────────────────────────────
  Gloo UI (service graph, BOTH clusters)   ${GLOO_URL}
  ────────────────────────────────────────────────────────────
  Graph tips for the demo:
    - tick both clusters + the bookinfo / petshop namespaces in the pickers
    - drop the time-interval picker (next to Refresh) to the smallest window
      so policy changes reshape the graph within a minute or two
  Port-forward log: /tmp/ambient-demo-gloo-ui-pf.log
  Stop it:          pkill -f 'port-forward.*gloo-mesh-ui'
EOF
