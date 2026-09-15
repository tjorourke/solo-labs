#!/usr/bin/env bash
# Harness entry point: up | test | teardown.
#
# Assumes a Kubernetes cluster with a GPU node is already there (the harness brings Part 3
# up first, which provides one). `up` installs the platform where it is missing, then the
# five steps of the flow. `test` runs the flow and the controls. `teardown` puts Part 3's
# routing back; it touches no infrastructure. Needs ANTHROPIC_API_KEY.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "${1:-}" in
  up)
    "$HERE/scripts/platform/up.sh"
    "$HERE/scripts/00-check.sh"
    "$HERE/scripts/01-identity.sh"
    "$HERE/scripts/02-router.sh"
    "$HERE/scripts/03-opa.sh"
    "$HERE/scripts/04-decision-gateway.sh"
    "$HERE/scripts/05-classify-gateway.sh"
    ;;
  test)
    "$HERE/scripts/06-test-flow.sh"
    "$HERE/scripts/07-test-controls.sh"
    ;;
  teardown)
    exec "$HERE/scripts/99-restore.sh"
    ;;
  *) echo "usage: $0 {up|test|teardown}" >&2; exit 1 ;;
esac
