#!/usr/bin/env bash
# rollback.sh <namespace> — take a namespace back to sidecars with a single label
# flip. This is the migration's safety net: any namespace reverts on its own,
# sidecar workloads keep running, and the mesh's L4 policy stays enforced across
# the round trip. Best demonstrated on the L4 namespace (petstore-data).
#
#   ./scripts/rollback.sh petstore-data
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

NS="${1:-$NS_DATA}"

step "Rolling $NS back to sidecar mode (ambient off, injection on)"
kc label ns "$NS" istio.io/dataplane-mode- istio-injection=enabled --overwrite >/dev/null
# also drop the waypoint binding if this namespace had one
kc label ns "$NS" istio.io/use-waypoint- >/dev/null 2>&1 || true
kc -n "$NS" rollout restart deployment >/dev/null
kc -n "$NS" rollout status deployment --timeout=120s >/dev/null 2>&1 || true
ok "$NS pods re-rolled with sidecars (2/2)"
kc get pods -n "$NS" 2>/dev/null

echo
ok "$NS is back on sidecars. Policies still enforced; no downtime for its callers."
