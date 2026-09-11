#!/usr/bin/env bash
# The gauges the Endpoint Picker reads, live, one line per replica.
#
#   ./scripts/metrics.sh          once
#   ./scripts/metrics.sh watch    every 2s until interrupted
#
# This is the whole input to the scheduling decision. Run the watch in a second terminal
# while a bench is going and you can watch a queue build on one replica and the next
# requests go to the other.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
resolve_ctx

run_once() {
  kc -n "$NS" exec -i deploy/loadgen -- python3 - < "$LAB_ROOT/scripts/metrics.py"
}

if [ "${1:-once}" = "watch" ]; then
  # A fresh exec each time rather than a loop inside the pod: cheaper to read, and
  # Ctrl-C actually stops it.
  while true; do clear; date; echo; run_once; sleep 2; done
else
  run_once
fi
