#!/usr/bin/env bash
# port-forward.sh — expose the gateway locally on :18080.
#
# The Enterprise AGW controller renders a Service named after the Gateway
# (vllm-gateway). If your AGW version names it differently, check:
#   kubectl --context kind-vllm-sr -n agentgateway-system get svc

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

step "Starting port-forward"
log "agentgateway → http://localhost:18080  (POST /v1/chat/completions)"
log "(Ctrl-C to stop)"
echo ""

cleanup() { jobs -p | xargs -r kill 2>/dev/null || true; }
trap cleanup EXIT INT TERM

kc -n agentgateway-system port-forward svc/vllm-gateway 18080:80 >/dev/null &
wait
