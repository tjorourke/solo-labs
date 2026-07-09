#!/usr/bin/env bash
# open-consoles.sh — open the web consoles. With the agentgateway ingress, every
# console is served at http://*.localtest.me on host :80 (kind maps host 80 -> the
# gateway NodePort), so there are NO port-forwards to keep running — this just opens
# the tabs. *.localtest.me resolves to 127.0.0.1 via public DNS (no /etc/hosts).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

step "Consoles (served by the agentgateway ingress — no port-forward)"
ok  "AgentRegistry   : http://${AR_HOST}"
ok  "Enterprise UI   : http://${KAGENT_UI_HOST}   (login admin-user / password)"
ok  "Keycloak        : http://${KEYCLOAK_HOST}"
ok  "Swagger Petstore: https://petstore.swagger.io   (the REST API / OpenAPI spec we expose as MCP tools in section 9)"
log "Chat with the agent from the CLI:  ./scripts/ask.sh \"<prompt>\""
log "AWS AgentCore : open the AWS console -> Bedrock AgentCore (manual)"
log "Google Cloud  : open the Google Cloud console -> Vertex AI (manual)"

URLS=("http://${AR_HOST}" "http://${KAGENT_UI_HOST}" "https://petstore.swagger.io")
if command -v open >/dev/null 2>&1; then open "${URLS[@]}" 2>/dev/null || true
elif command -v xdg-open >/dev/null 2>&1; then for u in "${URLS[@]}"; do xdg-open "$u" 2>/dev/null || true; done; fi
