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
bash "$SCRIPT_DIR/03b-telemetry.sh"     # ClickHouse + telemetry + Enterprise UI (Tracing + Agents). SKIP_TELEMETRY=true to skip
bash "$SCRIPT_DIR/04-agentregistry.sh"  # AgentRegistry IN-CLUSTER (replaces the old Docker daemon)
bash "$SCRIPT_DIR/05-waypoint.sh"       # ambient mesh + enterprise-agentgateway (GatewayClass for ingress + the AccessPolicy waypoint)
bash "$SCRIPT_DIR/06-gateway.sh"        # ingress Gateway + HTTPRoutes -> consoles at *.localtest.me (no port-forwards)
# From here arctl talks to the registry via the gateway issuer, so the gateway (06) must be up first.
bash "$SCRIPT_DIR/04b-register-runtime.sh"  # arctl login + register the kagent runtime
bash "$SCRIPT_DIR/04c-publish-mcp.sh"   # publish the approved MCP tool servers + skill
bash "$SCRIPT_DIR/04d-connect-aws.sh"   # connect the AWS Bedrock AgentCore runtime (CONNECT_AWS=false to skip)
bash "$SCRIPT_DIR/04e-connect-gcp.sh"   # connect the Google Cloud GeminiAgentRuntime (opt-in: set GCP_PROJECT_ID; skips otherwise)
bash "$SCRIPT_DIR/notebook-kernel.sh"   # register the Bash kernel demo.ipynb uses

cat >&2 <<EOF

══════════════════════════════════════════════════════════════════
  Platform ready — open demo.ipynb and start at "1. Scaffold"
══════════════════════════════════════════════════════════════════
  Context: $CTX
  Consoles (no port-forward — served by the agentgateway ingress):
    AgentRegistry : http://${AR_HOST}
    Enterprise UI : http://${KAGENT_UI_HOST}     (login admin-user / password)
    Keycloak      : http://${KEYCLOAK_HOST}
  The notebook's Connect cell loads .env.local and runs `arctl user login`.
EOF
