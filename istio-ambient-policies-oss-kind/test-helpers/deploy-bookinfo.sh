#!/usr/bin/env bash
# deploy-bookinfo.sh: TEST HELPER ONLY, used by scripts/e2e.sh. Readers use
# Flightbay's Deploy Bookinfo wizard instead (see the lab page). Applies the
# manifests Flightbay v0.4.5 bundles, in the order the wizard applies them.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/lib.sh
source "$HERE/../scripts/lib.sh"

step "TEST HELPER: Bookinfo from Flightbay's bundled manifests (the page uses the wizard)"
kc create namespace "$NS_APP" --dry-run=client -o yaml | kc apply -f - >/dev/null
show kc label namespace "$NS_APP" istio.io/dataplane-mode=ambient --overwrite
show kc -n "$NS_APP" apply -f "$HERE/bookinfo/waypoint-istio.yaml"
kc -n "$NS_APP" wait --for=condition=Programmed "gateway/$WAYPOINT_NAME" --timeout=180s >/dev/null
show kc label namespace "$NS_APP" "istio.io/use-waypoint=$WAYPOINT_NAME" --overwrite
show kc -n "$NS_APP" apply -f "$HERE/bookinfo/bookinfo.yaml" -f "$HERE/bookinfo/routing.yaml" -f "$HERE/bookinfo/client.yaml"
for d in details-v1 ratings-v1 productpage-v1 reviews-v1 reviews-v2 demo-client "$WAYPOINT_NAME"; do
  kc -n "$NS_APP" rollout status "deploy/$d" --timeout=300s >/dev/null
done
ok "Bookinfo running and enrolled in $NS_APP, waypoint $WAYPOINT_NAME Programmed"
