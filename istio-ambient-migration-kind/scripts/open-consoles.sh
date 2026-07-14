#!/usr/bin/env bash
# open-consoles.sh — open the two UIs the guide's per-step tabs show:
#
#   Gloo UI  (Solo's own service graph)  http://localhost:8090
#   Kiali    (istio graph)               http://localhost:20001
#
# Neither has an ingress on this kind cluster, so we start a detached
# port-forward for each (nohup + disown, so they survive this shell and leave no
# background job behind), wait until each answers, then open the browser tabs.
# Modeled on agentgw-multi-cluster-kind/demo-scripts/open-consoles.sh.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CTX="${CTX:-kind-ambient-migration}"
GLOO_MESH_NS="${GLOO_MESH_NS:-gloo-mesh}"
ISTIO_SYSTEM_NS="${ISTIO_SYSTEM_NS:-istio-system}"

GLOO_URL="http://localhost:8090"
KIALI_URL="http://localhost:20001"

# Start a detached port-forward only if the local port isn't already serving.
#   $1 url  $2 namespace  $3 svc/name  $4 localport:remoteport  $5 logfile
pf() {
  local url="$1" ns="$2" target="$3" ports="$4" logf="$5"
  if curl -fs -o /dev/null -m 2 "$url" 2>/dev/null; then return 0; fi
  nohup kubectl --context "$CTX" -n "$ns" port-forward "$target" "$ports" >"$logf" 2>&1 &
  disown 2>/dev/null || true
  for _ in $(seq 1 20); do
    curl -fs -o /dev/null -m 2 "$url" 2>/dev/null && return 0
    sleep 1
  done
  return 1
}

pf "$GLOO_URL"  "$GLOO_MESH_NS"    svc/gloo-mesh-ui 8090:8090   /tmp/ambient-gloo-ui-pf.log \
  || echo "! Gloo UI not reachable — is the management plane installed? (scripts/observability.sh)"
pf "$KIALI_URL" "$ISTIO_SYSTEM_NS" svc/kiali        20001:20001 /tmp/ambient-kiali-pf.log \
  || echo "! Kiali not reachable — is it installed? (scripts/observability.sh)"

# Open the tabs.
URLS=("$GLOO_URL" "$KIALI_URL")
if command -v open >/dev/null 2>&1; then
  open "${URLS[@]}" 2>/dev/null || true
elif command -v xdg-open >/dev/null 2>&1; then
  for u in "${URLS[@]}"; do xdg-open "$u" 2>/dev/null || true; done
fi

cat <<EOF

  Consoles (opening in your browser)
  ────────────────────────────────────────────────────────────
  Gloo UI   ${GLOO_URL}    Observability -> Graph -> cluster 'ambient-migration'
  Kiali     ${KIALI_URL}   Graph -> namespace petstore (+ petstore-legacy for the caller edges)
  ────────────────────────────────────────────────────────────
  Port-forwards run detached (logs: /tmp/ambient-gloo-ui-pf.log, /tmp/ambient-kiali-pf.log).
  Stop them with:  pkill -f 'port-forward.*(gloo-mesh-ui|svc/kiali)'
  Tip: pick petstore AND petstore-legacy in the namespace selector so the
  checkout/fortio -> catalog edges show; run some traffic first so edges light up.
EOF
