#!/usr/bin/env bash
# Harness entry point: up | test | teardown.
#
# This lab layers on agentgateway-inference-model-routing-eks and builds no
# infrastructure of its own. `up` checks that lab is working and adds one signal to its
# semantic router. `teardown` removes the signal and leaves the other lab as it was, so
# it is a no-op as far as cloud resources are concerned.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

case "${1:-}" in
  up)
    "$HERE/scripts/00-verify-prereqs.sh"
    "$HERE/scripts/01-deploy.sh"
    ;;
  test)
    exec "$HERE/scripts/02-test-routing.sh"
    ;;
  teardown)
    # Nothing cloud-billing is created by this lab, so teardown only unwinds the config.
    exec "$HERE/scripts/99-restore.sh"
    ;;
  *)
    echo "usage: $0 {up|test|teardown}" >&2
    exit 1
    ;;
esac
