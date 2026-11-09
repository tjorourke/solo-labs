#!/usr/bin/env bash
# Shortcut only. The lab page walks through every command by hand.
# No EXIT trap: nothing here tears down on exit or on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh
case "${1:-}" in
  up) exec bash scripts/up.sh ;;
  test) exec bash scripts/test.sh ;;
  up-kagent) exec bash scripts/up-kagent.sh ;;
  down-kagent) exec bash scripts/down-kagent.sh ;;
  test-agent) exec bash scripts/test-agent.sh ;;
  kagent-port-forward) start_kagent_port_forwards; echo "Solo UI http://localhost:19480, kagent API http://localhost:18083. Stop with: ./scripts/quick.sh stop-port-forward" ;;
  servers-up) servers_up ;;
  servers-down) servers_down ;;
  servers-status) servers_status ;;
  port-forward) start_port_forwards; echo "Port-forwards up (PIDs in $STATE_DIR). Stop with: ./scripts/quick.sh stop-port-forward" ;;
  stop-port-forward) stop_port_forwards ;;
  teardown)
    if [[ "${CONFIRM_TEARDOWN:-}" != "$CLUSTER" ]]; then
      echo "Only after review: CONFIRM_TEARDOWN=$CLUSTER ./scripts/quick.sh teardown" >&2
      exit 1
    fi
    stop_port_forwards
    kind delete cluster --name "$CLUSTER" || true
    servers_down || true
    # Read the state back rather than trusting the exit codes above.
    left=0
    if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then echo "Cluster $CLUSTER still exists" >&2; left=1; fi
    for p in 8001 8002 8003 8004; do
      if lsof -nP -iTCP:$p -sTCP:LISTEN >/dev/null 2>&1; then echo "Port $p still in use" >&2; left=1; fi
    done
    for f in "$STATE_DIR"/mcp-*.pid; do
      [[ -e $f ]] && kill -0 "$(cat "$f")" 2>/dev/null && { echo "MCP server PID $(cat "$f") still running" >&2; left=1; }
    done
    if [[ -f "$HOME/.codex/config.toml" ]] && grep -q 'xcloud-mcp lab' "$HOME/.codex/config.toml"; then
      echo 'Codex entries still present. Remove them with: ./scripts/codex-config.sh remove' >&2
    fi
    [[ $left == 0 ]] && echo "Gone: cluster $CLUSTER and all four MCP server processes." || exit 1 ;;
  *) echo 'Usage: ./scripts/quick.sh {up|test|up-kagent|down-kagent|test-agent|kagent-port-forward|servers-up|servers-down|servers-status|port-forward|stop-port-forward|teardown}' >&2; exit 2 ;;
esac
