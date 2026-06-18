#!/usr/bin/env bash
# aws-login.sh — SOURCE from the notebook:  source scripts/aws-login.sh
# Signs in to AWS (SSO) and hands the credentials to the arctl daemon (restart)
# so it can assume the cross-account role when it manages AgentCore. Sourced so
# the AWS_* exports persist into the kernel session.
if [ -z "${AWS_PROFILE:-}" ]; then
  echo "Set AWS_PROFILE in .env.local (./scripts/setup-env.sh) and re-run: source scripts/connect.sh"; return 2>/dev/null || exit 1
fi
aws sts get-caller-identity >/dev/null 2>&1 || aws sso login --profile "$AWS_PROFILE"
export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
eval "$(aws configure export-credentials --format env)"; export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
export DOCKER_REPO="${DOCKER_REPO:-solo-public/agentregistry-enterprise}" OIDC_AUTO_AUTH_ENABLED=true
arctl daemon stop >/dev/null 2>&1; arctl daemon start >/dev/null 2>&1
DC="$(docker ps --filter publish=12121 --format '{{.Names}}' | head -1)"; docker network connect kind "$DC" >/dev/null 2>&1 || true
sleep 5
export ARCTL_API_TOKEN="$(curl -s -X POST "$ARCTL_API_BASE_URL/api/autoauth/oauth/token" -H 'Content-Type: application/x-www-form-urlencoded' -d 'grant_type=client_credentials&client_id=admin&scope=openid profile email Groups' | jq -r .access_token)"
echo "AWS ****${AWS_ACCOUNT_ID: -4} / ${AWS_REGION} · daemon has credentials"
