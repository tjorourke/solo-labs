#!/usr/bin/env bash
# free-ports.sh — clear stray listeners off the local ports a demo uses, so a
# dev server or another lab's stale port-forward can't shadow the lab's own
# endpoints. (An SPA dev server answers 200 to everything, so the breakage
# only shows deep inside a request, e.g. a 404 opening an A2A stream.)
# Called by each notebook's Connect cell and by env.sh:
#
#   ./demo-scripts/free-ports.sh 8091 8095
#
# What survives:
#   - container-runtime listeners (OrbStack / Docker / vpnkit / lima / qemu):
#     they publish this lab's own container ports
#   - kubectl port-forwards for THIS suite's clusters (--context kind-mesh1|
#     kind-mesh2|kind-substrate|kind-inference), so re-running a Connect cell
#     mid-demo does not kill the consoles
# Everything else on a listed port is killed, and named as it goes.

KEEP_CONTEXTS="${KEEP_CONTEXTS:-kind-mesh1|kind-mesh2|kind-substrate|kind-inference}"

free_ports() {
  local port pid args name
  for port in "$@"; do
    for pid in $(lsof -nP -t -iTCP:"$port" -sTCP:LISTEN 2>/dev/null); do
      args="$(ps -o args= -p "$pid" 2>/dev/null)" || continue
      name="$(basename "$(ps -o comm= -p "$pid" 2>/dev/null)" 2>/dev/null)"
      case "$name" in
        [Oo]rb[Ss]tack*|*[Dd]ocker*|vpnkit*|qemu*|lima*|colima*) continue ;;
      esac
      if printf '%s' "$args" | grep -q 'port-forward' \
         && printf '%s' "$args" | grep -qE -- "--context (${KEEP_CONTEXTS})"; then
        continue
      fi
      printf '  freeing :%s (killing %s, pid %s)\n' "$port" "${name:-?}" "$pid" >&2
      kill "$pid" 2>/dev/null
    done
  done
  return 0
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  free_ports "$@"
fi
