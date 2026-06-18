#!/usr/bin/env bash
# setup.sh — engineer pre-demo setup. Run ONCE before opening demo.ipynb so the
# customer-facing notebook can start straight at the agent lifecycle.
#
# Brings up everything the demo runs ON (but not the demo steps themselves —
# the notebook does scaffold/build/publish/deploy live):
#   prereqs -> kind cluster + local registry -> Keycloak -> Solo kagent -> daemon
#
# Prereqs: a filled-in .env.local (run ./scripts/setup-env.sh) or the secrets
# exported in your shell.
#
#   ./scripts/setup-env.sh      # one-time: capture credentials
#   ./scripts/setup.sh          # bring up the platform (~15 min first run)
#   # then open demo.ipynb

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_secrets
bash "$SCRIPT_DIR/00-prereqs.sh"
bash "$SCRIPT_DIR/01-cluster.sh"
bash "$SCRIPT_DIR/02-keycloak.sh"
bash "$SCRIPT_DIR/03-kagent.sh"
bash "$SCRIPT_DIR/04-daemon.sh"
bash "$SCRIPT_DIR/04b-register-runtime.sh"
bash "$SCRIPT_DIR/04c-publish-mcp.sh"   # publish the approved MCP tool servers + skill
bash "$SCRIPT_DIR/05-waypoint.sh"       # ambient mesh + agentgateway waypoint (for AccessPolicy)
bash "$SCRIPT_DIR/06-kagent-ui-auth.sh" # kagent UI SSO front door (oauth2-proxy -> Keycloak)
bash "$SCRIPT_DIR/notebook-kernel.sh"   # register the Bash kernel demo.ipynb uses

cat >&2 <<EOF

══════════════════════════════════════════════════════════════════
  Platform ready — open demo.ipynb and start at "1. Scaffold"
══════════════════════════════════════════════════════════════════
  Context: $CTX        Registry UI: ${ARCTL_API_BASE_URL}
  The notebook's Connect cell loads .env.local and mints the arctl token.
EOF
