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
# It runs for MINUTES rather than for a fixed number of chats, because what you want
# while you talk is a board that keeps moving until you have finished the point. A chat
# budget cannot give you that: it depends on how long each answer takes, and a run that
# ends in forty seconds leaves you presenting a still picture.
#
# Tuning, if you ever want it (defaults are fine for a demo):
#   AGENTS=20 MINUTES=4 ./demo-scripts/substrate-load.sh
#   CHATS=60 ./demo-scripts/substrate-load.sh       # stop after 60 chats instead of on the clock
#   SUBSTRATE_CTX=<context>            target a different cluster
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCOPE="$SCRIPT_DIR/substrate-scope.sh"
AGENTS="${AGENTS:-12}"
MINUTES="${MINUTES:-2}"
# A ceiling, not the plan. The clock ends a healthy run long before this. It exists so a
# run whose chats fail instantly cannot sit there dispatching for the full two minutes.
CHATS="${CHATS:-$(( MINUTES * 60 ))}"
PORT="${SUBSTRATE_SCOPE_PORT:-8123}"
WATCHDOG_PID="${TMPDIR:-/tmp}/substrate-load.watchdog.pid"

[ -x "$SCOPE" ] || { echo "✗ no executable substrate-scope.sh beside this script ($SCOPE)"; exit 1; }

stop_watchdog() {
  [ -f "$WATCHDOG_PID" ] || return 0
  kill "$(cat "$WATCHDOG_PID" 2>/dev/null)" 2>/dev/null || true
  rm -f "$WATCHDOG_PID"
}

if [ "${1:-}" = "stop" ]; then
  stop_watchdog
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
  # Show the viewer's own reason rather than sending you off to run it again. The
  # usual one is that the Part 5 cluster is not there: this addresses it by context,
  # so it has to exist before anything can be visualised.
  if ! "$SCOPE"; then
    echo
    echo "✗ the viewer would not start. If the message above is about a missing"
    echo "  kind-substrate context, check 'kind get clusters'. If substrate is not"
    echo "  listed, build the Part 5 cluster first (a few minutes):"
    echo "      ./demo-scripts/substrate-cluster.sh"
    exit 1
  fi
fi

stop_watchdog
"$SCOPE" load "$AGENTS" "$CHATS"

# Ends the traffic on the clock, and leaves the board and the agents up so you can keep
# talking over what is on screen. Detached, so closing this terminal does not cancel it.
nohup bash -c "sleep $(( MINUTES * 60 )); '$SCOPE' pause" >/dev/null 2>&1 </dev/null &
echo $! > "$WATCHDOG_PID"

echo
echo "  Running for ${MINUTES} min, then the chats stop on their own and the board stays up."
echo "  Watch it: http://localhost:${PORT}"
echo "  Stop the chats now:  $SCOPE pause"
echo "  Done for now:  $0 stop"
