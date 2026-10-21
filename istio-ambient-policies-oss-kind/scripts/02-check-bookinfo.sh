#!/usr/bin/env bash
# 02-check-bookinfo.sh: run after Flightbay's Deploy Bookinfo wizard.
#
#   1. kubectl apply: the legacy namespace and its curl pod (outside the mesh)
#   2. check Flightbay enrolled bookinfo: dataplane-mode=ambient, use-waypoint,
#      the waypoint Programmed, every Bookinfo pod on HBONE in ztunnel
#   3. probe: everyone gets 200, nothing is denied yet
#
# BOOKINFO_HELPER=1 deploys Bookinfo with test-helpers/deploy-bookinfo.sh first.
# That is for the unattended harness only; the lab uses the wizard.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require kubectl

if [[ "${BOOKINFO_HELPER:-0}" == 1 ]]; then
  "$LAB_ROOT/test-helpers/deploy-bookinfo.sh"
fi
kc get deploy -n "$NS_APP" ratings-v1 >/dev/null 2>&1 \
  || die "Bookinfo is not in namespace $NS_APP. Deploy it with Flightbay's Deploy Bookinfo wizard first."

step "Deploying the legacy caller (outside the mesh)"
show kc apply -f "$LAB_ROOT/yaml/00-namespaces.yaml" -f "$LAB_ROOT/yaml/10-apps/"
kc -n "$NS_LEGACY" rollout status deploy/legacy --timeout=180s >/dev/null
ok "legacy is running, 1/1: no sidecar, no mesh label"

step "What Flightbay set on the bookinfo namespace"
show kc get namespace "$NS_APP" -L istio.io/dataplane-mode -L istio.io/use-waypoint
show kc -n "$NS_APP" get gateway "$WAYPOINT_NAME"
show ic ztunnel-config workloads --workload-namespace "$NS_APP"
log "PROTOCOL is HBONE for every Bookinfo pod: ztunnel carries their traffic over mTLS."

step "Before any policy"
"$SCRIPT_DIR/probe.sh" --no-jwt

echo
ok "Bookinfo is in the mesh, behind $WAYPOINT_NAME. Nothing is denied yet."
log "Next: ./scripts/03-strict-mtls.sh"
