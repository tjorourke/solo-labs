#!/usr/bin/env bash
# 05-migrate-l7.sh — migrate the L7 namespace (petstore) to ambient, behind a
# waypoint. Safe order: waypoint FIRST, then the targetRefs policy and the
# use-waypoint binding, THEN enrol and drop the old selector policy. The
# DestinationRule + VirtualService (subset canary, retries, timeout) keep working
# at the waypoint.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

step "1) Deploy the waypoint (before enrolment — petstore has an L7 policy)"
kapply "$LAB_ROOT/yaml/30-waypoints/petstore-waypoint.yaml"
kc -n "$NS_APP" wait --for=condition=Programmed gateway/waypoint --timeout=120s >/dev/null
ok "waypoint Programmed"

step "2) Translate the L7 policy selector → targetRefs, and bind catalog to the waypoint"
kapply "$LAB_ROOT/yaml/40-policies-waypoint/10-catalog-l7-authz-targetref.yaml"
kc -n "$NS_APP" label service catalog istio.io/use-waypoint=waypoint --overwrite >/dev/null
ok "targetRefs policy applied; catalog bound to waypoint"

step "3) Enrol petstore and remove the old selector policy"
kc label ns "$NS_APP" istio.io/dataplane-mode=ambient istio-injection- --overwrite >/dev/null
# In ambient a leftover L7 *selector* policy makes ztunnel fail-safe deny, so drop it.
kc -n "$NS_APP" delete authorizationpolicy catalog-get-only --ignore-not-found >/dev/null
kc -n "$NS_APP" rollout restart deploy/catalog-v1 deploy/catalog-v2 deploy/data-client >/dev/null
for d in catalog-v1 catalog-v2 data-client; do
  kc -n "$NS_APP" rollout status deploy/"$d" --timeout=120s >/dev/null
done
ok "catalog + data-client re-rolled with no sidecar (1/1); L7 now runs on the waypoint"
kc get pods -n "$NS_APP" 2>/dev/null | grep -E "catalog|data-client|waypoint" || true

echo
ok "$NS_APP is on ambient behind a waypoint. DR/VS routing + HTTP authz enforced there."
log "the sidecar checkout client is already routed through the waypoint (Solo interop)."
log "next: ./scripts/06-solo-interop.sh"
