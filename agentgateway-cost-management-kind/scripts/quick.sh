#!/usr/bin/env bash
# quick.sh — orchestrate the lab.
#   ./scripts/quick.sh up         # setup.sh: agentgateway, management UI, ClickHouse, cost pipeline
#   ./scripts/quick.sh seed       # backfill ClickHouse with history
#   ./scripts/quick.sh status     # cluster + gateway state
#   ./scripts/quick.sh teardown   # delete the kind cluster
#
# Added so labs-e2e.sh can run this lab unattended. Seeding stays a separate
# step, as setup.sh intends, so `up` does not decide how much history you want.
set -Euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER="${CLUSTER:-agentgateway-cost}"

cmd="${1:-up}"
case "$cmd" in
  up)       "$SCRIPT_DIR/setup.sh" ;;
  seed)     exec "$SCRIPT_DIR/seed-clickhouse.sh" ;;
  status)
    kind get clusters 2>/dev/null | sed 's/^/  /' >&2 || true
    kubectl --context "kind-${CLUSTER}" get gateway,httproute -A 2>/dev/null | sed 's/^/  /' >&2 || true
    ;;
  teardown) kind delete cluster --name "$CLUSTER" ;;
  *) echo "usage: quick.sh [up|seed|status|teardown]" >&2; exit 2 ;;
esac
