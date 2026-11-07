#!/usr/bin/env bash
# port-forward.sh — open the kagent dashboard and the hitl-extauth admin API locally.
#
# Runs both port-forwards in the foreground; Ctrl-C tears down both.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

step "Starting port-forwards"
log "kagent dashboard          → http://localhost:8080"
log "hitl-extauth admin API    → http://localhost:8081/pending"
log "(Ctrl-C to stop)"
echo ""

# Kill children on exit
cleanup() {
  jobs -p | xargs -r kill 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# kagent UI — the chart exposes svc/kagent-ui on port 8080
kc -n kagent port-forward svc/kagent-ui 8080:8080 >/dev/null &
# reviewer API — list parked calls and decide them
kc -n hitl port-forward svc/hitl-extauth-admin 8081:8081 >/dev/null &

wait
