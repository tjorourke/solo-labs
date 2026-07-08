#!/usr/bin/env bash
# open-consoles.sh — port-forward the Gloo UI (multicluster service graph) and
# print the console URLs. Run once; leave it running in a terminal.
set -Eeuo pipefail
CLUSTER1="${CLUSTER1:-kind-east-ag}"

# Gloo UI — the multicluster service graph. meshctl dashboard does the same,
# but a plain port-forward is easier to leave running from a notebook.
pkill -f "port-forward.*gloo-mesh-ui" 2>/dev/null || true
kubectl --context "$CLUSTER1" -n gloo-mesh port-forward svc/gloo-mesh-ui 8090:8090 \
  >/tmp/gloo-ui-pf.log 2>&1 &
sleep 2

ENT_UI="$(kubectl --context "$CLUSTER1" -n agentgateway-system \
  get svc solo-enterprise-ui -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"

cat <<EOF

  Consoles
  ────────────────────────────────────────────────────────────
  Gloo UI (service graph, both clusters)   http://localhost:8090
  Enterprise UI (agentgateway, tracing)    http://${ENT_UI:-<pending>}
  ────────────────────────────────────────────────────────────
  The Gloo UI service graph is where the cross-cluster hops light
  up while you run the exercises below.
EOF
