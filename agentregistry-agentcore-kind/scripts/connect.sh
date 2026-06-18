#!/usr/bin/env bash
# connect.sh — SOURCE from the notebook's first cell:  source scripts/connect.sh
# Loads .env.local, puts arctl on PATH, mints a Keycloak token (alice), shows the
# runtimes. The registry daemon is behind the SAME Keycloak as kagent, so this one
# token authenticates arctl AND is forwarded to the kagent controller on deploy.
# (Sourced, so the exports persist into the notebook's kernel session. No set -e
#  here — a hiccup must not kill the kernel.)
# Needs the Keycloak port-forward from ./scripts/open-consoles.sh (run first):
# keycloak.localtest.me resolves to 127.0.0.1 via public DNS, so no /etc/hosts.
LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
set -a
[ -f "$LAB_ROOT/.env.local" ] && . "$LAB_ROOT/.env.local"
[ -n "${SECRETS_FILE:-}" ] && [ -f "$SECRETS_FILE" ] && . "$SECRETS_FILE"
set +a
export PATH="$HOME/.arctl/bin:$PATH"
export NO_COLOR=1 CLICOLOR=0 TERM=dumb   # clean output (no color / terminal-probe escapes)
export CLUSTER_NAME="${CLUSTER_NAME:-agentcore-demo}"
export ARCTL_API_BASE_URL="${ARCTL_API_BASE_URL:-http://localhost:12121}"
export AS_USER="${AS_USER:-alice}"   # field-fte -> registry superuser + kagent Admin
export KEYCLOAK_OIDC_HOST="${KEYCLOAK_OIDC_HOST:-keycloak.localtest.me:18080}"
export ARCTL_API_TOKEN="$(curl -s -X POST "http://${KEYCLOAK_OIDC_HOST}/realms/solo/protocol/openid-connect/token" -H 'Content-Type: application/x-www-form-urlencoded' -d "grant_type=password&client_id=kagent&username=${AS_USER}&password=${AS_USER}" | jq -r .access_token)"
echo "arctl $(arctl version 2>/dev/null | awk '/arctl version/{print $3}') · $AS_USER token $([ -n "$ARCTL_API_TOKEN" ] && [ "$ARCTL_API_TOKEN" != null ] && echo ok || echo 'MISSING (run open-consoles.sh first)') · cluster kind-$CLUSTER_NAME"
arctl get runtimes
