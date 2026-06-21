#!/usr/bin/env bash
# aws-login.sh — SOURCE it:  source scripts/aws-login.sh
# Signs into AWS (SSO) and gives the IN-CLUSTER AgentRegistry server the AWS
# credentials it needs to assume the cross-account role and deploy to AWS Bedrock
# AgentCore — by helm-upgrading the registry with aws.enabled + the creds (the
# chart wires them into the server pod via a Secret + envFrom). Sourced so AWS_*
# persist into the kernel for ac-invoke. No `set -e` (a hiccup must not kill the
# notebook kernel).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
set -a; [ -f "$LAB_ROOT/.env.local" ] && . "$LAB_ROOT/.env.local"; [ -n "${SECRETS_FILE:-}" ] && [ -f "$SECRETS_FILE" ] && . "$SECRETS_FILE"; set +a
export PATH="$HOME/.arctl/bin:$PATH"
export CLUSTER_NAME="${CLUSTER_NAME:-agentcore-demo}"; export CTX="kind-${CLUSTER_NAME}"
export AR_NS="${AR_NS:-agentregistry-system}"
export AR_VERSION="${AR_VERSION:-2026.6.1}"
export AR_CHART="${AR_CHART:-oci://us-docker.pkg.dev/solo-public/agentregistry-enterprise/helm/agentregistry-enterprise}"
export GAR_HOST="${GAR_HOST:-us-docker.pkg.dev}"

if [ -z "${AWS_PROFILE:-}" ]; then
  echo "Set AWS_PROFILE in .env.local (./scripts/setup-env.sh), then: source scripts/aws-login.sh"; return 2>/dev/null || exit 1
fi
aws sts get-caller-identity >/dev/null 2>&1 || aws sso login --profile "$AWS_PROFILE"
export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
[ -n "$AWS_ACCOUNT_ID" ] || { echo "AWS login failed — run: aws sso login --profile $AWS_PROFILE"; return 2>/dev/null || exit 1; }
# SSO -> static temp creds so the in-cluster server can assume the cross-account role.
eval "$(aws configure export-credentials --format env 2>/dev/null)"; export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

if command -v gcloud >/dev/null 2>&1 && gcloud auth print-access-token >/dev/null 2>&1; then
  gcloud auth print-access-token | helm registry login -u oauth2accesstoken --password-stdin "$GAR_HOST" >/dev/null 2>&1 || true
fi
echo "→ giving the in-cluster registry server your AWS creds (helm upgrade)…"
helm --kube-context "$CTX" upgrade agentregistry "$AR_CHART" -n "$AR_NS" --version "$AR_VERSION" --reuse-values \
  --set aws.enabled=true \
  --set aws.accessKeyId="$AWS_ACCESS_KEY_ID" \
  --set aws.secretAccessKey="$AWS_SECRET_ACCESS_KEY" \
  --set aws.sessionToken="$AWS_SESSION_TOKEN" \
  --set aws.region="$AWS_REGION" >/dev/null 2>&1 \
  && echo "✓ registry upgraded with AWS creds" || echo "! helm upgrade failed — check: helm -n $AR_NS status agentregistry"
# The helm upgrade regenerates the Deployment, dropping the kubectl-added issuer
# hostAlias — re-add it so the server keeps resolving keycloak.localtest.me.
KCIP="$(kubectl --context "$CTX" -n keycloak get svc keycloak -o jsonpath='{.spec.clusterIP}' 2>/dev/null)"
[ -n "$KCIP" ] && { kubectl --context "$CTX" -n "$AR_NS" patch deploy agentregistry-enterprise-server --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/hostAliases\",\"value\":[{\"ip\":\"$KCIP\",\"hostnames\":[\"keycloak.localtest.me\"]}]}]" >/dev/null 2>&1 \
  || kubectl --context "$CTX" -n "$AR_NS" patch deploy agentregistry-enterprise-server --type=json \
  -p "[{\"op\":\"add\",\"path\":\"/spec/template/spec/hostAliases\",\"value\":[{\"ip\":\"$KCIP\",\"hostnames\":[\"keycloak.localtest.me\"]}]}]" >/dev/null 2>&1; }
kubectl --context "$CTX" -n "$AR_NS" rollout status deploy/agentregistry-enterprise-server --timeout=180s >/dev/null 2>&1 || true
echo "AWS ****${AWS_ACCOUNT_ID: -4} / ${AWS_REGION} · in-cluster registry has AWS creds"
