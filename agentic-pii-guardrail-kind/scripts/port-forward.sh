#!/usr/bin/env bash
# port-forward.sh — open the inspector UI and the gateway locally.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

step "Starting port-forwards"
log "inspector UI    → http://localhost:8090"
log "agentgateway    → http://localhost:8080  (raw /v1/messages endpoint)"
log "(Ctrl-C to stop)"
echo ""

cleanup() {
  jobs -p | xargs -r kill 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Inspector UI — svc/inspector-ui :80 → container :8080
kc -n pii-demo port-forward svc/inspector-ui 8090:80 >/dev/null &

# Gateway — the chart-rendered service is svc/pii-gateway :80 → container :8080
kc -n agentgateway-system port-forward svc/pii-gateway 8080:80 >/dev/null &

wait
