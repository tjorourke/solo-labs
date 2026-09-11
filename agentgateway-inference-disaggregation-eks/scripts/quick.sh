#!/usr/bin/env bash
# Harness entry point: up | test | teardown.
#
# This lab layers on agentgateway-inference-load-balancing-eks and builds no
# infrastructure of its own. `up` checks that lab is working, then re-roles its two GPU
# cards as one prefill worker and one decode worker. `teardown` puts them back, so as
# far as cloud billing is concerned it is a no-op: the dependency's teardown does the
# real work.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

case "${1:-}" in
  up)
    "$LAB_ROOT/scripts/00-verify-prereqs.sh"
    "$LAB_ROOT/scripts/01-deploy.sh"
    ;;
  test)
    exec "$LAB_ROOT/scripts/02-test.sh"
    ;;
  teardown)
    exec "$LAB_ROOT/scripts/99-restore.sh"
    ;;
  *)
    echo "usage: $0 {up|test|teardown}" >&2
    exit 1
    ;;
esac
