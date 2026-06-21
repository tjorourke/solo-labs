#!/usr/bin/env bash
# 04d-connect-aws.sh — connect the AWS Bedrock AgentCore platform to the registry
# ONCE, at cluster-deploy time. Mirrors 04b-register-runtime.sh (which connects
# the Kubernetes/kagent platform): the one-time, slow, scary parts live here so
# the notebook's AWS deploy is a clean per-agent step against an existing runtime.
#
# Provisions the cross-account IAM role (CloudFormation), ensures an ECR repo,
# and registers the BedrockAgentCore Runtime 'aws-agentcore' (the "connected
# platform"). Idempotent.
#
# AWS is opt-in. Skip with CONNECT_AWS=false (kagent-only demo). Needs an AWS
# session; runs aws-login if one isn't already present, and skips (not fails)
# with guidance if AWS still can't authenticate, so the rest of setup completes.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

if [[ "${CONNECT_AWS:-true}" == "false" ]]; then
  log "CONNECT_AWS=false — skipping the AWS Bedrock AgentCore platform"; exit 0
fi

step "Connecting the AWS Bedrock AgentCore platform"
# Pin us-east-1: Bedrock AgentCore isn't GA in every region (a stray AWS_REGION /
# profile region like eu-west-2 makes `runtime setup` / deploy fail), and the CF
# role + ECR + runtime must all share one region. Override AWS_REGION to use another.
export AWS_REGION="${AWS_REGION:-us-east-1}"
STACK="${STACK_NAME:-AgentRegistryAccess}"
ROLE_NAME="${AWS_ROLE_NAME:-AgentRegistryAccessRole-agentcore-demo}"

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  log "no AWS session — running aws-login"
  source "$SCRIPT_DIR/aws-login.sh" >&2 || true
fi
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  warn "no AWS session — SKIPPING the AWS platform (kagent still works)."
  warn "  connect it later:  source scripts/aws-login.sh && ./scripts/04d-connect-aws.sh"
  exit 0
fi
arctl_login
# `arctl runtime setup` (below) authenticates via ARCTL_API_TOKEN, not the keychain.
export ARCTL_API_TOKEN="$(arctl_token)"
[[ -n "$ARCTL_API_TOKEN" ]] || die "could not mint a registry token — is the gateway up so ${KEYCLOAK_ISSUER} resolves?"
AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ok "AWS $AWS_ACCOUNT_ID / $AWS_REGION"

# 1. cross-account IAM role via CloudFormation (idempotent)
mkdir -p "$LAB_ROOT/.agentcore"
arctl runtime setup bedrock-agent-core --aws-account-id "$AWS_ACCOUNT_ID" --role-name "$ROLE_NAME" \
  > "$LAB_ROOT/.agentcore/cf.yaml" 2> "$LAB_ROOT/.agentcore/setup.stderr" \
  || { cat "$LAB_ROOT/.agentcore/setup.stderr" >&2; die "arctl runtime setup failed"; }
AWS_EXTERNAL_ID="$(grep -ioE 'External ID:[[:space:]]*[A-Za-z0-9_-]+' "$LAB_ROOT/.agentcore/setup.stderr" | awk '{print $NF}' | head -1)"
[[ -n "$AWS_EXTERNAL_ID" ]] || die "could not parse External ID from arctl runtime setup"
if aws cloudformation describe-stacks --stack-name "$STACK" >/dev/null 2>&1; then
  ok "CloudFormation stack $STACK exists"
else
  aws cloudformation create-stack --stack-name "$STACK" --template-body "file://$LAB_ROOT/.agentcore/cf.yaml" --capabilities CAPABILITY_NAMED_IAM >/dev/null
  aws cloudformation wait stack-create-complete --stack-name "$STACK"; ok "CloudFormation stack $STACK created"
fi
AWS_ROLE_ARN="$(aws cloudformation describe-stacks --stack-name "$STACK" --query 'Stacks[0].Outputs[?OutputKey==`RoleArn`].OutputValue' --output text)"

# 2. ECR repo for the agent image (idempotent)
aws ecr describe-repositories --repository-names agentdemo >/dev/null 2>&1 \
  || aws ecr create-repository --repository-name agentdemo >/dev/null
ok "ECR repo agentdemo ready"

# 3. register the BedrockAgentCore Runtime — the "connected platform"
RT="$(mktemp)"; cat > "$RT" <<EOF
apiVersion: ar.dev/v1alpha1
kind: Runtime
metadata: {name: aws-agentcore}
spec:
  type: BedrockAgentCore
  telemetryEndpoint: ${AR_TELEMETRY_ENDPOINT}
  config: {roleArn: "${AWS_ROLE_ARN}", externalId: "${AWS_EXTERNAL_ID}", region: "${AWS_REGION}"}
EOF
arctl apply -f "$RT"; rm -f "$RT"

step "Verifying the AWS platform is registered and ready"
arctl get runtime aws-agentcore >/dev/null 2>&1 || die "aws-agentcore runtime not registered"
case "$(aws cloudformation describe-stacks --stack-name "$STACK" --query 'Stacks[0].StackStatus' --output text 2>/dev/null)" in
  *COMPLETE) ok "CloudFormation stack $STACK ready" ;;
  *) die "CloudFormation stack $STACK is not in a COMPLETE state" ;;
esac
aws ecr describe-repositories --repository-names agentdemo >/dev/null 2>&1 || die "ECR repo agentdemo missing"
ok "AWS Bedrock AgentCore platform 'aws-agentcore' registered and verified (role + ECR ready)"
arctl get runtimes 2>/dev/null | sed 's/^/  /' >&2 || true
