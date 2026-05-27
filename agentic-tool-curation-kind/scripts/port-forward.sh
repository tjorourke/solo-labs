#!/usr/bin/env bash
# port-forward.sh — expose the Curation Inspector UI locally.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

step "Starting port-forwards"
log "curation-inspector-ui → http://localhost:8090   (★ THE LAB DEMO)"
log "(Ctrl-C to stop)"
echo ""

cleanup() {
  jobs -p | xargs -r kill 2>/dev/null || true
}
trap cleanup EXIT INT TERM

kc -n tool-curation port-forward svc/curation-inspector-ui 8090:8080 >/dev/null &

wait
