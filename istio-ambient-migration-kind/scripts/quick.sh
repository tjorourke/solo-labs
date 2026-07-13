#!/usr/bin/env bash
# quick.sh — one-shot driver for the whole migration (used by the E2E runner and
# for a fast local stand-up).
#
#   ./scripts/quick.sh up         # cluster → apps → flip → L4 → L7 → interop → HTTPRoute
#   ./scripts/quick.sh test       # health-check snapshot
#   ./scripts/quick.sh teardown   # delete the kind cluster
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

cmd="${1:-up}"
case "$cmd" in
  up)
    "$SCRIPT_DIR/01-cluster.sh"
    "$SCRIPT_DIR/02-apps.sh"
    "$SCRIPT_DIR/03-flip-ambient.sh"
    "$SCRIPT_DIR/04-migrate-l4.sh"
    "$SCRIPT_DIR/05-migrate-l7.sh"
    "$SCRIPT_DIR/06-solo-interop.sh"
    "$SCRIPT_DIR/07-httproute.sh"
    ok "migration complete — run './scripts/quick.sh test' for a health snapshot"
    ;;
  test)
    "$SCRIPT_DIR/health-check.sh"
    ;;
  teardown)
    "$SCRIPT_DIR/../demo-scripts/reset.sh"
    ;;
  *)
    die "usage: quick.sh [up|test|teardown]"
    ;;
esac
