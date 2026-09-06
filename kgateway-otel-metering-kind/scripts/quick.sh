#!/usr/bin/env bash
# quick.sh — orchestrate the lab.
#   ./scripts/quick.sh up         # 00 -> 04: OpenMeter, cluster, kgateway, app, collector
#   ./scripts/quick.sh demo       # drive traffic and show the meter
#   ./scripts/quick.sh status     # cluster + gateway state
#   ./scripts/quick.sh teardown   # cleanup.sh: cluster and the OpenMeter compose stack
#
# Added so labs-e2e.sh can run this lab unattended; the numbered scripts and
# their order are unchanged, this only calls them.
set -Euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

cmd="${1:-up}"
case "$cmd" in
  up)
    "$SCRIPT_DIR/00-openmeter.sh"
    "$SCRIPT_DIR/01-cluster.sh"
    "$SCRIPT_DIR/02-kgateway.sh"
    "$SCRIPT_DIR/03-app.sh"
    "$SCRIPT_DIR/04-collector.sh"
    step "Up. Next: ./scripts/quick.sh demo"
    ;;
  demo)     exec "$SCRIPT_DIR/demo.sh" ;;
  status)
    step "Cluster";  kind get clusters 2>/dev/null | sed 's/^/  /' >&2 || true
    step "Gateway";  kubectl --context "kind-${CLUSTER:-kgw-metering}" get gateway,httproute -A 2>/dev/null | sed 's/^/  /' >&2 || true
    ;;
  teardown) exec "$SCRIPT_DIR/cleanup.sh" ;;
  *) echo "usage: quick.sh [up|demo|status|teardown]" >&2; exit 2 ;;
esac
