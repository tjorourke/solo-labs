#!/usr/bin/env bash
# quick.sh — orchestrate the lab.
#   ./scripts/quick.sh up          # setup-cluster.sh: kind, Helm, operator, mesh in SIDECAR mode
#   ./scripts/quick.sh observability  # the Gloo UI and Kiali the write-up shows
#   ./scripts/quick.sh status      # cluster + mesh state
#   ./scripts/quick.sh teardown    # delete the kind cluster
#
# Added so labs-e2e.sh can run this lab unattended. `up` covers the automated
# part only: setup-cluster.sh deliberately stops with the mesh in sidecar mode,
# and the migration itself is plain YAML the reader applies step by step. There
# is no `test` here for that reason, so the harness runs up and teardown.
set -Euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-ambient-migration}"

cmd="${1:-up}"
case "$cmd" in
  up)            "$SCRIPT_DIR/setup-cluster.sh" ;;
  observability) exec "$SCRIPT_DIR/observability.sh" ;;
  status)
    kind get clusters 2>/dev/null | sed 's/^/  /' >&2 || true
    kubectl --context "kind-${CLUSTER_NAME}" get pods -n istio-system 2>/dev/null | sed 's/^/  /' >&2 || true
    ;;
  teardown)      kind delete cluster --name "$CLUSTER_NAME" ;;
  *) echo "usage: quick.sh [up|observability|status|teardown]" >&2; exit 2 ;;
esac
