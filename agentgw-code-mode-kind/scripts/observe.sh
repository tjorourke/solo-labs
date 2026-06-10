#!/usr/bin/env bash
# observe.sh [debug|trace] — turn the gateway data-plane log level up at runtime
# and tail its logs, so you can watch the run_code call and the upstream REST
# calls the sandbox makes to the petstore. No restart: it uses the admin endpoint
# (POST /logging) and resets the level back to info on exit.
#
#   ./scripts/observe.sh                 # debug — shows the "upstream request" lines
#   ./scripts/observe.sh trace           # full outbound request URIs + headers
#
# Then, in another terminal:  ./scripts/run-code.sh   (or ./scripts/ask-llm.sh "...")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

LEVEL="${1:-debug}"
ADMIN_LOCAL_PORT="${ADMIN_LOCAL_PORT:-15900}"   # high local port; maps to the pod's admin :15000

POD="$(kc -n "$AGW_NS" get pod -l "gateway.networking.k8s.io/gateway-name=${GATEWAY_NAME}" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
[[ -n "$POD" ]] || die "gateway pod not found — is the lab up? (./scripts/quick.sh status)"

step "Opening the data-plane admin endpoint ($POD :15000)"
kc -n "$AGW_NS" port-forward "$POD" "${ADMIN_LOCAL_PORT}:15000" >/tmp/code-mode-admin-pf.$$ 2>&1 &
APF=$!
trap 'curl -s -X POST "http://127.0.0.1:'"${ADMIN_LOCAL_PORT}"'/logging?level=info" >/dev/null 2>&1; kill "$APF" 2>/dev/null' EXIT
for _ in $(seq 1 20); do
  curl -s -o /dev/null "http://127.0.0.1:${ADMIN_LOCAL_PORT}/logging" && break; sleep 1
done

step "Setting log level → ${LEVEL}"
curl -s -X POST "http://127.0.0.1:${ADMIN_LOCAL_PORT}/logging?level=${LEVEL}" | sed 's/^/  /' >&2

step "Tailing ${POD} (Ctrl-C to stop; level resets to info)"
log "in another terminal:  ./scripts/run-code.sh   or   ./scripts/ask-llm.sh \"...\""
log "watch for:  'request ... gen_ai.tool.name=run_code'  (inbound)  and"
log "            'upstream request ... http.path=/api/v3/... http.status=200'  (GW → petstore)"
exec kc -n "$AGW_NS" logs -f "$POD"
