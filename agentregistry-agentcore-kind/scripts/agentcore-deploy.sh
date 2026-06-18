#!/usr/bin/env bash
# agentcore-deploy.sh — deploy the dice agentdemo to AWS Bedrock AgentCore in one
# command. Makes the scaffolded agent multi-cloud (BedrockClaude), grants the
# cross-account role, registers the runtime, pushes the image to ECR + source to
# git, and applies the Deployment. Run after: source scripts/aws-login.sh
#
#   ./scripts/agentcore-deploy.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
require aws; require docker; require jq; require arctl; require git
cd "$LAB_ROOT"; arctl_token
export AWS_REGION="${AWS_REGION:-us-east-1}"
# agentdemo/ is scaffolded at the lab root (next to demo.ipynb), so it
# stays visible in the Explorer.
DEMO_ROOT="$LAB_ROOT"
AGENT=agentdemo; PROJ="$DEMO_ROOT/agentdemo"; STACK="${STACK_NAME:-AgentRegistryAccess}"

step "Preflight"
aws sts get-caller-identity >/dev/null 2>&1 || die "no AWS session — run: source scripts/aws-login.sh"
[[ -d "$PROJ" ]] || die "no agentdemo/ project — run the scaffold cell first"
AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
: "${AGENT_GIT_URL:?set AGENT_GIT_URL in .env.local (./scripts/setup-env.sh)}"
ok "AWS ${AWS_ACCOUNT_ID} / ${AWS_REGION}"

step "Making the agent multi-cloud (BedrockClaude via MODEL_PROVIDER)"
cp "$LAB_ROOT/templates/bedrock_model.py" "$PROJ/agentdemo/bedrock_model.py"
python3 - "$PROJ" <<'PY'
import re, sys, pathlib
proj = pathlib.Path(sys.argv[1])
p = proj/'agentdemo'/'agent.py'; s = p.read_text()
if 'MODEL_PROVIDER' not in s:
    s = s.replace('from google.adk.models.lite_llm import LiteLlm\n', '')
    new = ('def create_model():\n'
           '    import os\n'
           '    if os.environ.get("MODEL_PROVIDER", "anthropic").lower() == "bedrock":\n'
           '        from .bedrock_model import BedrockClaude\n'
           '        return BedrockClaude(model=os.environ.get("MODEL_NAME", "us.anthropic.claude-haiku-4-5-20251001-v1:0"))\n'
           '    from google.adk.models.lite_llm import LiteLlm\n'
           '    return LiteLlm(model=os.environ.get("MODEL_NAME", "anthropic/claude-haiku-4-5"))\n')
    s = re.sub(r'def create_model\(\):.*?(?=\n\nroot_agent|\nroot_agent|\Z)', new.rstrip()+'\n', s, count=1, flags=re.S)
    p.write_text(s)
pp = proj/'pyproject.toml'; t = pp.read_text()
if 'anthropic[bedrock]' not in t:
    pp.write_text(t.replace('dependencies = [', 'dependencies = [\n  "anthropic[bedrock]>=0.40",', 1))
print("multi-cloud patch applied")
PY
ok "agent is multi-cloud"

step "Cross-account role (CloudFormation)"
mkdir -p "$LAB_ROOT/.agentcore"
arctl runtime setup bedrock-agent-core --aws-account-id "$AWS_ACCOUNT_ID" --role-name "AgentRegistryAccessRole-agentcore-demo" \
  2> >(tee "$LAB_ROOT/.agentcore/setup.stderr" >&2) > "$LAB_ROOT/.agentcore/cf.yaml" || die "runtime setup failed"
AWS_EXTERNAL_ID="$(grep -ioE 'External ID:[[:space:]]*[A-Za-z0-9_-]+' "$LAB_ROOT/.agentcore/setup.stderr" | awk '{print $NF}' | head -1)"
[[ -n "$AWS_EXTERNAL_ID" ]] || die "could not parse External ID"
if aws cloudformation describe-stacks --stack-name "$STACK" >/dev/null 2>&1; then ok "stack exists"; else
  aws cloudformation create-stack --stack-name "$STACK" --template-body "file://$LAB_ROOT/.agentcore/cf.yaml" --capabilities CAPABILITY_NAMED_IAM >/dev/null
  aws cloudformation wait stack-create-complete --stack-name "$STACK"; ok "stack created"; fi
AWS_ROLE_ARN="$(aws cloudformation describe-stacks --stack-name "$STACK" --query 'Stacks[0].Outputs[?OutputKey==`RoleArn`].OutputValue' --output text)"

step "Registering the BedrockAgentCore runtime 'aws-agentcore'"
RT="$(mktemp)"; cat > "$RT" <<EOF
apiVersion: ar.dev/v1alpha1
kind: Runtime
metadata: {name: aws-agentcore}
spec:
  type: BedrockAgentCore
  config: {roleArn: "${AWS_ROLE_ARN}", externalId: "${AWS_EXTERNAL_ID}", region: "${AWS_REGION}"}
EOF
arctl apply -f "$RT"; rm -f "$RT"; ok "runtime registered"

step "Pushing the agent image to ECR (linux/amd64)"
ECR_HOST="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"; ECR_IMAGE="${ECR_HOST}/${AGENT}:0.0.1"
aws ecr describe-repositories --repository-names "$AGENT" >/dev/null 2>&1 || aws ecr create-repository --repository-name "$AGENT" >/dev/null
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_HOST" >/dev/null
arctl build "$PROJ" --push --platform linux/amd64 --image "$ECR_IMAGE"; ok "pushed $ECR_IMAGE"

step "Pushing the agent source to git (AgentCore clones it)"
SLUG="${AGENT_GIT_URL#https://github.com/}"; SLUG="${SLUG%.git}"; BR="${AGENT_GIT_BRANCH:-main}"
PUSH_URL="$AGENT_GIT_URL"
command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 && PUSH_URL="https://x-access-token:$(gh auth token)@github.com/${SLUG}.git"
T="$(mktemp -d)"; cp -R "$PROJ" "$T/$AGENT"
( cd "$T" && git init -qb "$BR" && git add -A && git -c user.email=demo@local -c user.name=demo commit -qm "agentdemo source" \
  && git remote add origin "$PUSH_URL" && git push -fq origin "$BR" ) && ok "pushed source to $SLUG@$BR"
rm -rf "$T"
CLONE_URL="$AGENT_GIT_URL"
[[ "$(gh repo view "$SLUG" --json isPrivate -q .isPrivate 2>/dev/null)" == "true" ]] && CLONE_URL="https://x-access-token:$(gh auth token)@github.com/${SLUG}.git"

step "Re-publishing the agent (bedrock + ECR + git) and deploying to AgentCore"
A="$(mktemp)"; cat > "$A" <<EOF
apiVersion: ar.dev/v1alpha1
kind: Agent
metadata: {name: ${AGENT}}
spec:
  description: Dice-rolling agent (roll_die, check_prime).
  modelName: us.anthropic.claude-haiku-4-5-20251001-v1:0
  modelProvider: bedrock
  source:
    image: ${ECR_IMAGE}
    repository: {url: ${CLONE_URL}, branch: ${BR}, subfolder: ${AGENT}}
EOF
arctl apply -f "$A"; rm -f "$A"
D="$(mktemp)"; cat > "$D" <<EOF
apiVersion: ar.dev/v1alpha1
kind: Deployment
metadata: {name: ${AGENT}-agentcore}
spec:
  targetRef: {kind: Agent, name: ${AGENT}}
  runtimeRef: {kind: Runtime, name: aws-agentcore}
  runtimeConfig: {region: ${AWS_REGION}}
  env: {MODEL_PROVIDER: bedrock, AWS_REGION: ${AWS_REGION}}
EOF
arctl apply -f "$D"; rm -f "$D"

step "Waiting for the AWS runtime (CREATING -> READY)"
for i in $(seq 1 25); do
  S="$(aws bedrock-agentcore-control list-agent-runtimes --region "$AWS_REGION" 2>/dev/null | jq -r '.agentRuntimes[]?|select(.agentRuntimeName=="agentdemo_agentcore")|.status')"
  log "[$i] agentdemo_agentcore: ${S:-<none>}"; echo "$S" | grep -qiE 'READY|FAILED' && break; sleep 30
done
ok "AgentCore deploy submitted — test with:  ./scripts/ac-invoke.sh"
