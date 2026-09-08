#!/usr/bin/env bash
# substrate-scope.sh — run Substrate Scope, a live visualiser for Agent Substrate, against
# the Part 5 cluster. You watch worker bays fill, actors resume from snapshots and get
# checkpointed back, which is the thing demo-5 otherwise has to prove with ps and ls.
#
# Runs from the suite root or from demo-scripts/ — it resolves everything from its own
# location, never from the current directory:
#
#   ./demo-scripts/substrate-scope.sh [cmd]   # from the suite root
#   ./substrate-scope.sh [cmd]                # from demo-scripts/
#
#   (no args)        start it, prints the URL
#   load [N] [B]     N agents, then B real chats at them
#   stop             stop the viewer and any load
#   clean            delete the agents load created
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
# NOT ${CTX:-...}: connect.sh and env.sh both export CTX=kind-mesh1, so a shell that has
# sourced either would silently point this at mesh1 — where a SandboxAgent is rejected
# with `unknown field "spec.substrate"` because mesh1 carries no substrate. Use a name
# nothing else exports, and override deliberately with SUBSTRATE_CTX=... if you need to.
CTX="${SUBSTRATE_CTX:-kind-substrate}"
DIR="$SCRIPT_DIR/.substrate-scope"
REPO="https://github.com/themsquared/substrate-scope.git"
PIN="${SUBSTRATE_SCOPE_REF:-952c386777638e1e3a0a2c3e10c7021fe217a38f}"
PORT="${SUBSTRATE_SCOPE_PORT:-8123}"
LOG="${TMPDIR:-/tmp}/substrate-scope.log"
# It is started from inside $DIR, so its argv is a bare "node server.mjs" with no path:
# a pkill pattern matching the directory would never find it. Track the pid instead.
PIDF="${TMPDIR:-/tmp}/substrate-scope.pid"
load_stop() {
  pkill -f 'node stimulate.mjs' 2>/dev/null || true
  curl -s -X POST "http://localhost:${PORT}/demo" -d '{"run":false}' -m 3 >/dev/null 2>&1 || true
}

# Every path that touches the cluster calls this. Checked here rather than inline in the
# start path because `load` and `clean` exit before that runs, and pointing load at a
# cluster without substrate produces an opaque strict-decoding error on spec.substrate.
require_substrate() {
  kubectl config get-contexts "$CTX" >/dev/null 2>&1 || {
    echo "✗ no $CTX context — run $SCRIPT_DIR/substrate-cluster.sh first"; exit 1; }
  kubectl --context "$CTX" get crd workerpools.ate.dev >/dev/null 2>&1 || {
    echo "✗ $CTX has no Agent Substrate installed (no workerpools.ate.dev)."
    echo "  This needs the Part 5 cluster: $SCRIPT_DIR/substrate-cluster.sh"
    echo "  If you meant a different cluster, set SUBSTRATE_CTX=<context>."
    exit 1; }
}

scope_stop() {
  local pid
  load_stop
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

if [ "${1:-}" = "clean" ]; then
  require_substrate
  kubectl --context "$CTX" -n kagent delete sandboxagent -l scope-load=true --ignore-not-found
  echo "✔ load agents removed"
  exit 0
fi

if [ "${1:-}" = "load" ]; then
  require_substrate
  N="${2:-6}"; BUDGET="${3:-30}"
  curl -sf -o /dev/null -m 5 "http://localhost:${PORT}/" || { echo "✗ start it first: $0"; exit 1; }
  echo "→ deploying $N SandboxAgents (labelled scope-load=true, remove with '$0 clean')"
  for i in $(seq 1 "$N"); do
    kubectl --context "$CTX" apply -f - >/dev/null <<YAML
apiVersion: kagent.dev/v1alpha2
kind: SandboxAgent
metadata:
  name: scope-agent-$i
  namespace: kagent
  labels: { scope-load: "true" }
spec:
  type: Declarative
  description: load agent $i for the Substrate Scope board
  declarative: { runtime: go, modelConfig: default-model-config, systemMessage: "You are agent $i, an SRE assistant running in a gVisor sandbox." }
  substrate: { workerPoolRef: { name: kagent-default } }
YAML
  done
  for i in $(seq 1 "$N"); do
    kubectl --context "$CTX" -n kagent wait sandboxagent/scope-agent-$i --for=condition=Ready --timeout=120s >/dev/null 2>&1       || echo "  scope-agent-$i not Ready yet (it will join the board when it is)"
  done
  echo "✔ $N agents Ready"
  # /demo is the visualiser's billing switch and defaults to OFF, so the load
  # generator refuses to dispatch until it is flipped. These are REAL model calls.
  curl -s -X POST "http://localhost:${PORT}/demo" -d '{"run":true}' -m 5 >/dev/null
  pkill -f 'node stimulate.mjs' 2>/dev/null || true
  cd "$DIR"
  nohup node stimulate.mjs --budget "$BUDGET" >"${TMPDIR:-/tmp}/substrate-stimulate.log" 2>&1 </dev/null &
  cd - >/dev/null
  echo "▶ sending $BUDGET real chats at them — these are billable model calls, and it stops at the budget"
  echo "  watch http://localhost:${PORT} : bays light up, actors resume from snapshots, then checkpoint back"
  echo "  log: ${TMPDIR:-/tmp}/substrate-stimulate.log   stop early: $0 stop"
  exit 0
fi

command -v node >/dev/null 2>&1 || { echo "✗ node 18+ required (it has no npm dependencies, just the runtime)"; exit 1; }
require_substrate

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
  echo "  log: $LOG   stop: $0 stop"
else
  echo "✗ it did not come up — last lines of $LOG:"; tail -15 "$LOG"; exit 1
fi
