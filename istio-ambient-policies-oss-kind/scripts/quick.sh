#!/usr/bin/env bash
# quick.sh: the harness entry point every lab in this repo shares.
#
#   ./scripts/quick.sh up          # build the cluster, apply every policy, assert (scripts/e2e.sh)
#                                  # Bookinfo comes from test-helpers/deploy-bookinfo.sh here;
#                                  # the lab page uses Flightbay's Deploy Bookinfo wizard
#   ./scripts/quick.sh test        # assert against a cluster that is already up
#   ./scripts/quick.sh teardown    # kind delete cluster --name ambient-policies-lab
#
# scripts/lib.sh sources the repo-wide versions.env matrix, but this lab pins
# upstream OSS Istio, which the matrix has no key for (it tracks the Solo build
# as SOLO_ISTIO_VERSION). Override ISTIO_VERSION to move it.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-up}" in
  up)            exec "$SCRIPT_DIR/e2e.sh" ;;
  test|verify)   exec "$SCRIPT_DIR/e2e.sh" --test ;;
  teardown|down) exec "$SCRIPT_DIR/99-teardown.sh" ;;
  *) echo "usage: $0 up|test|teardown" >&2; exit 2 ;;
esac
