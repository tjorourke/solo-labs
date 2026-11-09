#!/usr/bin/env bash
# Fallback path. Prints export lines for a dev-user token from Keycloak (password grant, ar-cli-password client).
# The token carries aud ar-backend and mcp-gateway, so it works for the registry MCP and the gateway.
# Use:  eval "$(./scripts/mint-token.sh)"      Tokens expire (Keycloak default 5 minutes); re-run before the demo.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh
t=$(mint_token "${1:-dev-user}")
[[ $t == ey* ]] || { echo 'No token. Is the Keycloak port-forward on 8180 up?' >&2; exit 1; }
echo "export LAB_MCP_TOKEN=$t"
echo "export LAB_AR_TOKEN=$t"
