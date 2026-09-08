#!/usr/bin/env bash
# substrate-load.sh — one command to make the Substrate Scope board busy.
#
#   ./demo-scripts/substrate-load.sh          # everything: viewer up, agents up, chats running
#   ./demo-scripts/substrate-load.sh stop     # stop the chats, remove the agents, stop the viewer
#
# That is the whole interface. It starts the viewer if it is not already running, so
# there is nothing to remember and nothing to do in order.
#
# Runs from anywhere (suite root, demo-scripts/, absolute path) and NEVER changes your
# kubectl context: it addresses the Part 5 cluster with --context and the viewer gets its
# own pinned kubeconfig, so you can stay on mesh1 for demo 4 in the same terminal.
#
# Tuning, if you ever want it (defaults are fine for a demo):
#   AGENTS=10 CHATS=60 ./demo-scripts/substrate-load.sh
#   SUBSTRATE_CTX=<context>            target a different cluster
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCOPE="$SCRIPT_DIR/substrate-scope.sh"
AGENTS="${AGENTS:-6}"
CHATS="${CHATS:-40}"
PORT="${SUBSTRATE_SCOPE_PORT:-8123}"

[ -x "$SCOPE" ] || { echo "✗ no executable substrate-scope.sh beside this script ($SCOPE)"; exit 1; }

if [ "${1:-}" = "stop" ]; then
  "$SCOPE" clean || true     # remove the load agents
  "$SCOPE" stop  || true     # stop the generator and the viewer
  exit 0
fi

# Start the viewer only if it is not already answering, so re-running this is harmless
# and the order you do things in does not matter.
if curl -sf -o /dev/null -m 4 "http://localhost:${PORT}/" 2>/dev/null; then
  echo "→ viewer already up at http://localhost:${PORT}"
else
  echo "→ starting the viewer"
  "$SCOPE" >/dev/null || { echo "✗ viewer failed to start — run $SCOPE on its own to see why"; exit 1; }
fi

"$SCOPE" load "$AGENTS" "$CHATS"
echo
echo "  Watch it: http://localhost:${PORT}"
echo "  Done for now:  $0 stop"
