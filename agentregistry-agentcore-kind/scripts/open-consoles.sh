#!/usr/bin/env bash
# open-consoles.sh — open the web consoles the demo shows. RUN THIS IN A
# TERMINAL (not a notebook cell — it starts background port-forwards).
#
#   AgentRegistry UI : http://localhost:12121   (the local daemon, already bound)
#   kagent UI        : http://localhost:18007    (via oauth2-proxy SSO; login alice / alice)
#
# Two forwards back the kagent UI:
#   oauth2-proxy :18007   the SSO front door the browser hits
#   keycloak     :18080   the IdP; the browser is redirected to the issuer
#                         keycloak.localtest.me:18080, which public DNS resolves
#                         to 127.0.0.1 (no /etc/hosts, no sudo). High port so it
#                         never collides with a local `arctl run` agent on :8080.
#
# AWS Bedrock AgentCore is shown manually in the AWS console (no local URL).
# Leave this running during the demo; Ctrl-C tears the forwards down.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

REGISTRY_URL="${ARCTL_API_BASE_URL:-http://localhost:12121}"
KAGENT_URL="http://localhost:18007"

step "Port-forwarding the kagent UI (oauth2-proxy:18007) + Keycloak (:18080)"
kc -n kagent port-forward svc/oauth2-proxy 18007:4180 >/tmp/kagent-ui-pf.log 2>&1 &
PF1=$!
# Keycloak on host :18080 so the browser's SSO redirect to the issuer
# (keycloak.localtest.me:18080) resolves; pods reach it via a hostAlias.
# High port so it never shadows a local `arctl run` agent bound to host :8080.
kc -n "${KEYCLOAK_NS:-keycloak}" port-forward svc/keycloak 18080:8080 >/tmp/keycloak-pf.log 2>&1 &
PF2=$!
trap 'kill $PF1 $PF2 2>/dev/null' EXIT INT TERM
sleep 2

ok "AgentRegistry UI : $REGISTRY_URL"
ok "kagent UI        : $KAGENT_URL   (login: alice / alice  — real Keycloak user, field-fte → Admin)"
log "AWS AgentCore    : open the AWS console → Bedrock AgentCore (manual)"

if command -v open >/dev/null 2>&1; then
  open "$REGISTRY_URL" "$KAGENT_URL"
elif command -v xdg-open >/dev/null 2>&1; then
  xdg-open "$REGISTRY_URL"; xdg-open "$KAGENT_URL"
fi

echo >&2
log "Consoles open. Leave this terminal running; Ctrl-C to stop the forwards."
wait
