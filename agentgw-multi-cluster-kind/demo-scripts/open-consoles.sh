#!/usr/bin/env bash
# open-consoles.sh — open the demo consoles.
#
# Modeled on agentregistry-agentcore-kind/deploy/scripts/open-consoles.sh, which
# opens the console browser tabs with `open`. That lab reaches every console over
# an ingress, so it needs no port-forward. The Gloo UI here has no ingress, so we
# also start its port-forward — fully detached (nohup + disown) so it keeps
# running after this script returns and leaves no job in your shell.
CLUSTER1="${CLUSTER1:-kind-east-ag}"

GLOO_URL="http://localhost:8090"

ENT_UI="$(kubectl --context "$CLUSTER1" -n agentgateway-system \
  get svc solo-enterprise-ui -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"

# Start the Gloo UI port-forward only if 8090 isn't already serving. Detach it
# so it survives this shell (no trailing background job → no shell-integration noise).
if ! curl -fs -o /dev/null -m 2 "$GLOO_URL" 2>/dev/null; then
  nohup kubectl --context "$CLUSTER1" -n gloo-mesh \
    port-forward svc/gloo-mesh-ui 8090:8090 >/tmp/gloo-ui-pf.log 2>&1 &
  disown 2>/dev/null || true
  for _ in $(seq 1 20); do
    curl -fs -o /dev/null -m 2 "$GLOO_URL" 2>/dev/null && break
    sleep 1
  done
fi

# Open the console tabs in the browser (the template's pattern).
URLS=("$GLOO_URL")
[ -n "$ENT_UI" ] && URLS+=("http://${ENT_UI}")
if command -v open >/dev/null 2>&1; then
  open "${URLS[@]}" 2>/dev/null || true
elif command -v xdg-open >/dev/null 2>&1; then
  for u in "${URLS[@]}"; do xdg-open "$u" 2>/dev/null || true; done
fi

cat <<EOF

  Consoles (opening in your browser)
  ────────────────────────────────────────────────────────────
  Gloo UI (service graph, both clusters)   ${GLOO_URL}
  Enterprise UI (agentgateway, tracing)    http://${ENT_UI:-<pending>}
  ────────────────────────────────────────────────────────────
  The Gloo UI port-forward runs in the background (log: /tmp/gloo-ui-pf.log).
  Stop it with:  pkill -f 'port-forward.*gloo-mesh-ui'
  Watch the cross-cluster hops light up in the service graph.
EOF
