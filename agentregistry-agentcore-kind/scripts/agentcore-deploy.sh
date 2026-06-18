#!/usr/bin/env bash
# agentcore-deploy.sh — deploy the scaffolded agent to the AWS Bedrock AgentCore
# platform that 04d-connect-aws.sh connected at setup time. Per-agent work only:
# make the agent multi-cloud, push its image to ECR + source to git, then
# arctl apply the Agent and a Deployment that targets the 'aws-agentcore' runtime.
# The cross-account role, ECR repo, and runtime registration already exist (04d),
# so there is no CloudFormation/role setup here.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
arctl_token
export AWS_REGION="${AWS_REGION:-us-east-1}"
AGENT=agentdemo; PROJ="$LAB_ROOT/agentdemo"

step "Preflight"
aws sts get-caller-identity >/dev/null 2>&1 || die "no AWS session — run: source scripts/aws-login.sh"
arctl get runtime aws-agentcore >/dev/null 2>&1 || die "AWS platform not connected — run ./scripts/04d-connect-aws.sh (or re-run setup.sh)"
[[ -d "$PROJ" ]] || die "no agentdemo/ project — scaffold it in the notebook first"
: "${AGENT_GIT_URL:?set AGENT_GIT_URL in .env.local}"
AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ok "AWS $AWS_ACCOUNT_ID / $AWS_REGION → platform aws-agentcore"

step "Making the agent multi-cloud (Bedrock model via MODEL_PROVIDER)"
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
print("  multi-cloud patch applied")
PY
ok "agent is multi-cloud"

step "Pushing the agent image to ECR (linux/amd64)"
ECR_HOST="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"; ECR_IMAGE="${ECR_HOST}/${AGENT}:0.0.1"
aws ecr describe-repositories --repository-names "$AGENT" >/dev/null 2>&1 || aws ecr create-repository --repository-name "$AGENT" >/dev/null
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_HOST" >/dev/null
arctl build "$PROJ" --push --platform linux/amd64 --image "$ECR_IMAGE"; ok "pushed $ECR_IMAGE"

step "Pushing the agent source to git (AgentCore clones it)"
SLUG="${AGENT_GIT_URL#https://github.com/}"; SLUG="${SLUG%.git}"; BR="${AGENT_GIT_BRANCH:-main}"
CLONE_URL="https://x-access-token:$(gh auth token)@github.com/${SLUG}.git"
T="$(mktemp -d)"; cp -R "$PROJ" "$T/$AGENT"
( cd "$T" && git init -qb "$BR" && git add -A \
  && git -c user.email=demo@local -c user.name=demo commit -qm "agentdemo source" \
  && git remote add origin "$CLONE_URL" && git push -fq origin "$BR" ) && ok "pushed source to $SLUG@$BR"
rm -rf "$T"

step "Deploying the agent to the aws-agentcore platform"
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

step "Waiting for the AWS runtime (CREATING → READY)"
for i in $(seq 1 25); do
  S="$(aws bedrock-agentcore-control list-agent-runtimes --region "$AWS_REGION" 2>/dev/null | jq -r '.agentRuntimes[]?|select(.agentRuntimeName=="agentdemo_agentcore")|.status')"
  log "[$i] agentdemo_agentcore: ${S:-<none>}"
  echo "$S" | grep -qiE 'READY|FAILED' && break
  sleep 30
done
ok "AgentCore deploy submitted — test with ./scripts/ac-invoke.sh"
