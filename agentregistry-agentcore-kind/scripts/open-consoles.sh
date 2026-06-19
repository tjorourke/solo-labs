#!/usr/bin/env bash
# open-consoles.sh — open the web consoles the demo shows. RUN THIS IN A
# TERMINAL (not a notebook cell — it starts background port-forwards).
#
#   AgentRegistry UI : http://localhost:12121   (the local daemon, already bound)
#   kagent UI        : http://localhost:18007    (via oauth2-proxy SSO; login alice / alice)
#   Enterprise UI    : http://localhost:18090    (Solo Enterprise for kagent — the
#                                                 Dashboard/Agents/Tracing console;
#                                                 login alice / alice via Keycloak)
#
# Forwards:
#   oauth2-proxy     :18007   the kagent UI's SSO front door the browser hits
#   solo-enterprise-ui :18090 the Enterprise management UI (Tracing lives here, not
#                             in the kagent UI); it logs in via Keycloak too.
#   keycloak         :18080   the IdP; the browser is redirected to the issuer
#                             keycloak.localtest.me:18080, which public DNS resolves
#                             to 127.0.0.1 (no /etc/hosts, no sudo). High port so it
#                             never collides with a local `arctl run` agent on :8080.
#
# AWS Bedrock AgentCore is shown manually in the AWS console (no local URL).
# Leave this running during the demo; Ctrl-C tears the forwards down.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

REGISTRY_URL="${ARCTL_API_BASE_URL:-http://localhost:12121}"
KAGENT_URL="http://localhost:18007"
ENTERPRISE_URL="http://localhost:18090"

step "Port-forwarding the consoles (kagent UI, Enterprise UI, Keycloak)"
kc -n kagent port-forward svc/oauth2-proxy 18007:4180 >/tmp/kagent-ui-pf.log 2>&1 &
PF1=$!
# Keycloak on host :18080 so the browser's SSO redirect to the issuer
# (keycloak.localtest.me:18080) resolves; pods reach it via a hostAlias.
# High port so it never shadows a local `arctl run` agent bound to host :8080.
kc -n "${KEYCLOAK_NS:-keycloak}" port-forward svc/keycloak 18080:8080 >/tmp/keycloak-pf.log 2>&1 &
PF2=$!
# The Enterprise UI (solo-enterprise-ui) is the Solo Enterprise management console
# — Dashboard/Agents/Tracing. Tracing lives HERE, not in the kagent UI. Present
# only when the management chart is installed (03b-telemetry.sh; skipped via
# SKIP_TELEMETRY=true), so forward it conditionally.
PF3=""
if kc -n "${SOLO_MGMT_NS:-solo-enterprise}" get svc solo-enterprise-ui >/dev/null 2>&1; then
  kc -n "${SOLO_MGMT_NS:-solo-enterprise}" port-forward svc/solo-enterprise-ui 18090:80 >/tmp/enterprise-ui-pf.log 2>&1 &
  PF3=$!
fi
trap 'kill $PF1 $PF2 $PF3 2>/dev/null' EXIT INT TERM
sleep 2

ok "AgentRegistry UI : $REGISTRY_URL"
ok "kagent UI        : $KAGENT_URL   (login: alice / alice  — real Keycloak user, field-fte → Admin)"
[[ -n "$PF3" ]] && ok "Enterprise UI    : $ENTERPRISE_URL   (Tracing tab; login: alice / alice via Keycloak)" \
                 || log "Enterprise UI    : not installed (run 03b-telemetry.sh for the Tracing console)"
log "AWS AgentCore    : open the AWS console → Bedrock AgentCore (manual)"

if command -v open >/dev/null 2>&1; then
  open "$REGISTRY_URL" "$KAGENT_URL" ${PF3:+"$ENTERPRISE_URL"}
elif command -v xdg-open >/dev/null 2>&1; then
  xdg-open "$REGISTRY_URL"; xdg-open "$KAGENT_URL"; [[ -n "$PF3" ]] && xdg-open "$ENTERPRISE_URL"
fi

echo >&2
log "Consoles open. Leave this terminal running; Ctrl-C to stop the forwards."
wait
