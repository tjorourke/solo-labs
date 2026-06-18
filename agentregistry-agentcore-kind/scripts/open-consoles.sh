#!/usr/bin/env bash
# open-consoles.sh — open the two web consoles the demo shows. RUN THIS IN A
# TERMINAL (not a notebook cell — it starts background port-forwards).
#
#   AgentRegistry UI : http://localhost:12121     (the local daemon, already bound)
#   kagent UI        : http://localhost:8083      (port-forward to kagent-controller)
#
# AWS Bedrock AgentCore is shown manually in the AWS console (no local URL).
#
# Leave this running during the demo; Ctrl-C tears the port-forward down.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

REGISTRY_URL="${ARCTL_API_BASE_URL:-http://localhost:12121}"
KAGENT_URL="http://localhost:8080"

step "Port-forwarding the kagent UI (kagent-ui:8080)"
kc -n kagent port-forward svc/kagent-ui 8080:8080 >/tmp/kagent-ui-pf.log 2>&1 &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null' EXIT INT TERM
sleep 2

ok "AgentRegistry UI : $REGISTRY_URL"
ok "kagent UI        : $KAGENT_URL"
log "AWS AgentCore    : open the AWS console → Bedrock AgentCore (manual)"

if command -v open >/dev/null 2>&1; then
  open "$REGISTRY_URL" "$KAGENT_URL"
elif command -v xdg-open >/dev/null 2>&1; then
  xdg-open "$REGISTRY_URL"; xdg-open "$KAGENT_URL"
fi

echo >&2
log "Consoles open. Leave this terminal running; Ctrl-C to stop the kagent port-forward."
wait $PF_PID
