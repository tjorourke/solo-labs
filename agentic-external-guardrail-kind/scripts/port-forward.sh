#!/usr/bin/env bash
# port-forward.sh — open the gateway and the two custom services locally.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

step "Starting port-forwards"
log "agentgateway     → http://localhost:8080  (raw /v1/messages endpoint)"
log "guard-adapter    → http://localhost:8000  (/events, /healthz)"
log "trustguard-stub  → http://localhost:8081  (/received, stub mode only)"
log "(Ctrl-C to stop)"
echo ""

cleanup() { jobs -p | xargs -r kill 2>/dev/null || true; }
trap cleanup EXIT INT TERM

kc -n agentgateway-system port-forward svc/extguard-gateway 8080:80 >/dev/null &
kc -n extguard-demo port-forward svc/guard-adapter 8000:8000 >/dev/null &
kc -n extguard-demo port-forward svc/trustguard-stub 8081:8080 >/dev/null 2>&1 &

wait
