#!/usr/bin/env bash
# substrate-scope.sh — run Substrate Scope, a live visualiser for Agent Substrate, against
# the Part 5 cluster. You watch worker bays fill, actors resume from snapshots and get
# checkpointed back, which is the thing demo-5 otherwise has to prove with ps and ls.
#
#   ./demo-scripts/substrate-scope.sh          # start it, prints the URL
#   ./demo-scripts/substrate-scope.sh stop     # stop it
#
# Third party (Mike Moore, Apache-2.0): https://github.com/themsquared/substrate-scope
# It is NOT vendored here. This clones it under demo-scripts/.substrate-scope (gitignored)
# and pins a reviewed commit, because it runs locally with your kubectl credentials.
#
# What it does with those credentials: reads workerpools, pods, actortemplates, nodes and
# node stats, and calls the kagent controller API through a port-forward it manages. It
# writes ONLY when you click a control in its UI (kubectl scale workerpools / rollout
# restart), so treat the scaling buttons as live actions on the cluster.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CTX="${CTX:-kind-substrate}"
DIR="$SCRIPT_DIR/.substrate-scope"
REPO="https://github.com/themsquared/substrate-scope.git"
PIN="${SUBSTRATE_SCOPE_REF:-952c386777638e1e3a0a2c3e10c7021fe217a38f}"
PORT="${SUBSTRATE_SCOPE_PORT:-8123}"
LOG="${TMPDIR:-/tmp}/substrate-scope.log"
# It is started from inside $DIR, so its argv is a bare "node server.mjs" with no path:
# a pkill pattern matching the directory would never find it. Track the pid instead.
PIDF="${TMPDIR:-/tmp}/substrate-scope.pid"
scope_stop() {
  local pid
  [ -f "$PIDF" ] && pid="$(cat "$PIDF" 2>/dev/null)" || pid=""
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null; rm -f "$PIDF"; return 0; fi
  rm -f "$PIDF"
  pkill -f 'node server.mjs --live' 2>/dev/null && return 0
  return 1
}

if [ "${1:-}" = "stop" ]; then
  scope_stop && echo "✔ Substrate Scope stopped" || echo "not running"
  exit 0
fi

command -v node >/dev/null 2>&1 || { echo "✗ node 18+ required (it has no npm dependencies, just the runtime)"; exit 1; }
kubectl config get-contexts "$CTX" >/dev/null 2>&1 || { echo "✗ no $CTX context — run ./demo-scripts/substrate-cluster.sh first"; exit 1; }

if [ ! -d "$DIR/.git" ]; then
  echo "→ cloning substrate-scope at $PIN ..."
  git clone -q "$REPO" "$DIR"
fi
git -C "$DIR" fetch -q origin 2>/dev/null || true
git -C "$DIR" checkout -q "$PIN" 2>/dev/null || { echo "✗ could not check out pin $PIN"; exit 1; }

# It watches the CURRENT kubectl context, so point that at the substrate cluster. Every
# other lab in this suite passes --context explicitly, so this is the one place it matters.
PREV="$(kubectl config current-context 2>/dev/null || true)"
[ "$PREV" = "$CTX" ] || { kubectl config use-context "$CTX" >/dev/null; echo "→ kubectl context switched to $CTX (was ${PREV:-none})"; }

scope_stop || true      # a previous run would otherwise hold the port
sleep 1
# Detach properly: every fd redirected and no wrapping subshell, or the caller (a
# notebook cell, or this script's own shell) blocks until the server exits.
cd "$DIR"
nohup node server.mjs --live >"$LOG" 2>&1 </dev/null &
echo $! > "$PIDF"
cd - >/dev/null
sleep 5
if curl -sf -o /dev/null -m 10 "http://localhost:${PORT}/"; then
  SRC=$(grep -m1 '^source:' "$LOG" 2>/dev/null | awk '{print $2}')
  echo "✔ Substrate Scope → http://localhost:${PORT}   (source: ${SRC:-unknown})"
  [ "$SRC" = "kagent" ] \
    && echo "  full fidelity: it is reading the controller's substrate inventory, so actors and sessions are real" \
    || echo "  kubectl-only fallback: pools/workers/templates are live, per-session actor state is not"
  echo "  deploy a SandboxAgent (5.1) and chat with it (5.6) to light the board up"
  echo "  log: $LOG   stop: ./demo-scripts/substrate-scope.sh stop"
else
  echo "✗ it did not come up — last lines of $LOG:"; tail -15 "$LOG"; exit 1
fi
