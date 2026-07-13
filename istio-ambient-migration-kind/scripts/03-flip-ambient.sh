#!/usr/bin/env bash
# 03-flip-ambient.sh — turn the whole mesh from sidecar to ambient by editing ONE
# field on the ServiceMeshController (dataplaneMode: Sidecar → Ambient). The Gloo
# Operator adds the istio-cni + ztunnel node components; running sidecar workloads
# are not touched, so the flip itself is zero-downtime. Nothing is enrolled yet.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

step "Flipping ServiceMeshController to dataplaneMode: Ambient"
kapply "$LAB_ROOT/yaml/00-mesh/smc-ambient.yaml"

log "waiting for the ztunnel DaemonSet to appear …"
end=$(( $(date +%s) + 180 ))
until kc -n "$ISTIO_SYSTEM_NS" get ds ztunnel >/dev/null 2>&1; do
  [[ $(date +%s) -ge $end ]] && die "ztunnel not created within 3m — check the operator logs"
  sleep 5
done
kc -n "$ISTIO_SYSTEM_NS" rollout status ds/ztunnel --timeout=120s >/dev/null
ok "ztunnel rolled out — mesh is now ambient-capable"

step "Sidecar workloads are untouched (still 2/2, no restart)"
kc get pods -n "$NS_APP" 2>/dev/null | grep -E "catalog|data-client" || true

echo
ok "Ambient enabled. ztunnel + istio-cni run per node; sidecars keep serving until enrolled."
log "next: ./scripts/04-migrate-l4.sh"
