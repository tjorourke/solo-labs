#!/usr/bin/env bash
# quick.sh — the labs-e2e entry point for this lab.
#
#   ./scripts/quick.sh up         run every sub-lab against the standing clusters
#   ./scripts/quick.sh teardown   no-op, see below
#
# This lab has no infrastructure of its own. It layers on top of the
# agentgw-multi-cluster-kind standup, so the manifest declares that as a
# dependsOn and the harness brings it up first and tears it down afterwards.
# Tearing anything down here would pull the ground out from under that.
#
# Each sub-lab is idempotent, so a re-run is safe.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ -f "${SECRETS_FILE:-}" ]] && { set -a; . "$SECRETS_FILE"; set +a; }

case "${1:-up}" in
  up)       bash "$SCRIPT_DIR/run-lab.sh" all ;;
  test)     bash "$SCRIPT_DIR/health-check.sh" ;;
  teardown) echo "quick.sh: nothing to tear down; the clusters belong to agentgw-multi-cluster-kind" ;;
  *)        echo "usage: quick.sh up|test|teardown" >&2; exit 2 ;;
esac
