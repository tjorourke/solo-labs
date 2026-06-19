#!/usr/bin/env bash
# aws-login.sh — SOURCE it:  source scripts/aws-login.sh
# Signs into AWS (SSO) and restarts the arctl daemon behind the SAME Keycloak as
# the rest of the lab — NOT autoauth — WITH AWS credentials in its environment, so:
#   • the kagent runtime + Enterprise UI keep working (Keycloak bearer forwarding), and
#   • the daemon can assume the cross-account role to deploy/manage AgentCore.
# Sourced so AWS_* + the token persist into the kernel. No `set -e` (a hiccup must
# not kill the notebook kernel). Needs the open-consoles Keycloak forward (:18080).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
set -a; [ -f "$LAB_ROOT/.env.local" ] && . "$LAB_ROOT/.env.local"; [ -n "${SECRETS_FILE:-}" ] && [ -f "$SECRETS_FILE" ] && . "$SECRETS_FILE"; set +a
export PATH="$HOME/.arctl/bin:$PATH"
export AS_USER="${AS_USER:-alice}"
export KEYCLOAK_OIDC_HOST="${KEYCLOAK_OIDC_HOST:-keycloak.localtest.me:18080}"
export ARCTL_API_BASE_URL="${ARCTL_API_BASE_URL:-http://localhost:12121}"

if [ -z "${AWS_PROFILE:-}" ]; then
  echo "Set AWS_PROFILE in .env.local (./scripts/setup-env.sh), then: source scripts/aws-login.sh"; return 2>/dev/null || exit 1
fi
aws sts get-caller-identity >/dev/null 2>&1 || aws sso login --profile "$AWS_PROFILE"
export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
# Temp creds as env vars (SSO -> static) so the daemon container can assume the role.
eval "$(aws configure export-credentials --format env)"; export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

# Restart the daemon behind Keycloak WITH these AWS creds. 04-daemon.sh is idempotent
# and re-establishes the Keycloak OIDC env + socat issuer bridge + docker networks +
# health wait; the AWS_* we just exported are inherited by its `arctl daemon start`
# and land in the daemon container (the compose interpolates them). This replaces the
# old autoauth restart, which broke the kagent runtime/UI.
bash "$SCRIPT_DIR/04-daemon.sh"

# Mint alice's Keycloak token for arctl (same as connect.sh; uses the open-consoles
# :18080 forward — keycloak.localtest.me resolves to 127.0.0.1 via public DNS).
export ARCTL_API_TOKEN="$(curl -s -X POST "http://${KEYCLOAK_OIDC_HOST}/realms/solo/protocol/openid-connect/token" -H 'Content-Type: application/x-www-form-urlencoded' -d "grant_type=password&client_id=kagent&username=${AS_USER}&password=${AS_USER}" | jq -r .access_token)"
echo "AWS ****${AWS_ACCOUNT_ID: -4} / ${AWS_REGION} · daemon behind Keycloak + AWS creds · ${AS_USER} token $([ -n "$ARCTL_API_TOKEN" ] && [ "$ARCTL_API_TOKEN" != null ] && echo ok || echo 'MISSING (run open-consoles.sh first)')"
