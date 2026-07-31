#!/bin/bash
# Fast path for the E2E runner and for anyone who just wants the whole thing.
#
#   scripts/quick.sh up        build and verify
#   scripts/quick.sh test      verify an existing build
#   scripts/quick.sh demo      run every feature and HA demo in order
#   scripts/quick.sh teardown  destroy
#
# Prefer the numbered scripts when you are presenting: they explain themselves as
# they go. This one is for CI and for rebuilds.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

S="$LAB_DIR/scripts"

case "${1:-up}" in
  up)
    "$S/00-preflight.sh"
    "$S/01-apply.sh"
    "$S/02-verify.sh"
    ;;
  test)
    "$S/02-verify.sh"
    ;;
  features)
    for s in 10-routing 11-auth 12-llm 13-mcp 15-ratelimit; do
      hdr "scripts/$s.sh"; "$S/$s.sh"
    done
    ;;
  ha)
    for s in 20-ha-node-loss 21-ha-mcp-session 22-ha-config-push 23-ha-ui-overlay; do
      hdr "scripts/$s.sh"; "$S/$s.sh"
    done
    ;;
  demo)
    "$0" features
    "$0" ha
    ;;
  teardown)
    LAB_FORCE=1 "$S/teardown.sh"
    ;;
  *)
    die "usage: $0 [up|test|features|ha|demo|teardown]"
    ;;
esac
