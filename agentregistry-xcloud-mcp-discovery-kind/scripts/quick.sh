#!/usr/bin/env bash
# Shortcut only. The lab page walks through every command by hand.
# No EXIT trap: nothing here tears down on exit or on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh
case "${1:-}" in
  up) exec bash scripts/up.sh ;;
  test) exec bash scripts/test.sh ;;
  port-forward) start_port_forwards; echo "Port-forwards up (PIDs in $STATE_DIR). Stop with: ./scripts/quick.sh stop-port-forward" ;;
  stop-port-forward) stop_port_forwards ;;
  teardown)
    if [[ "${CONFIRM_TEARDOWN:-}" != "$CLUSTER" ]]; then
      echo "Only after review: CONFIRM_TEARDOWN=$CLUSTER ./scripts/quick.sh teardown" >&2
      exit 1
    fi
    stop_port_forwards
    kind delete cluster --name "$CLUSTER" || true
    docker rm -f ext-mcp-cloud-a ext-mcp-cloud-b >/dev/null 2>&1 || true
    # Read the state back rather than trusting the exit codes above.
    left=0
    if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then echo "Cluster $CLUSTER still exists" >&2; left=1; fi
    if docker ps -a --format '{{.Names}}' | grep -Eq '^ext-mcp-cloud-(a|b)$'; then echo 'ext-mcp containers still exist' >&2; left=1; fi
    if [[ -f "$HOME/.codex/config.toml" ]] && grep -q 'xcloud-mcp lab' "$HOME/.codex/config.toml"; then
      echo 'Codex entries still present. Remove them with: ./scripts/codex-config.sh remove' >&2
    fi
    [[ $left == 0 ]] && echo "Gone: cluster $CLUSTER and both ext-mcp containers." || exit 1 ;;
  *) echo 'Usage: ./scripts/quick.sh {up|test|port-forward|stop-port-forward|teardown}' >&2; exit 2 ;;
esac
