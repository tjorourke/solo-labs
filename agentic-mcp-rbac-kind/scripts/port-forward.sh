#!/usr/bin/env bash
# port-forward.sh — expose the RBAC Inspector UI (the actual lab demo) and
# the kagent dashboard locally.
#
# Runs both port-forwards in the foreground; Ctrl-C tears down both.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

step "Starting port-forwards"
log "rbac-inspector-ui  → http://localhost:8090   (★ THE LAB DEMO)"
log "kagent dashboard   → http://localhost:8080   (general agent UI, NOT this lab)"
log "(Ctrl-C to stop)"
echo ""

echo "  The lab demo is at localhost:8090 (RBAC Inspector)." >&2
echo "  The kagent dashboard at localhost:8080 is the cluster's general" >&2
echo "  agent dashboard — not part of this lab." >&2
echo "" >&2

cleanup() {
  jobs -p | xargs -r kill 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# rbac-inspector-ui — the actual lab demo.
kc -n mcp-rbac port-forward svc/rbac-inspector-ui 8090:8080 >/dev/null &
# kagent UI — kept around because the chart is installed; not part of this lab.
kc -n kagent port-forward svc/kagent-ui 8080:8080 >/dev/null &

wait
