#!/usr/bin/env bash
# connect.sh — SOURCE from the notebook's first cell:  source scripts/connect.sh
# Loads .env.local, puts arctl on PATH, mints a catalog token, shows the runtimes.
# (Sourced, so the exports persist into the notebook's kernel session. No set -e
#  here — a hiccup must not kill the kernel.)
LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
set -a
[ -f "$LAB_ROOT/.env.local" ] && . "$LAB_ROOT/.env.local"
[ -n "${SECRETS_FILE:-}" ] && [ -f "$SECRETS_FILE" ] && . "$SECRETS_FILE"
set +a
export PATH="$HOME/.arctl/bin:$PATH"
export NO_COLOR=1 CLICOLOR=0 TERM=dumb   # clean output (no color / terminal-probe escapes)
export CLUSTER_NAME="${CLUSTER_NAME:-agentcore-demo}"
export ARCTL_API_BASE_URL="${ARCTL_API_BASE_URL:-http://localhost:12121}"
export ARCTL_API_TOKEN="$(curl -s -X POST "$ARCTL_API_BASE_URL/api/autoauth/oauth/token" -H 'Content-Type: application/x-www-form-urlencoded' -d 'grant_type=client_credentials&client_id=admin&scope=openid profile email Groups' | jq -r .access_token)"
echo "arctl $(arctl version 2>/dev/null | awk '/arctl version/{print $3}') · token $([ -n "$ARCTL_API_TOKEN" ] && echo ok || echo MISSING) · cluster kind-$CLUSTER_NAME"
arctl get runtimes
