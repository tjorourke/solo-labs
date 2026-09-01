#!/usr/bin/env bash
# 31-agents.sh — two agents, four deployments, all in SOURCE mode (no ECR, no
# docker build): AgentCore clones the public git repo, and the registry uploads
# the source bundle to S3 under the assumed AgentRegistryAccess role. Source
# mode is a hard requirement here — portfolio B's operator role cannot create
# ECR repositories, and source mode never needs one.
#
#   poet  - answers with a short rhyme around the dice tools
#   quant - terse, numbers-only answers, same tools
#
# Deployments: {poet,quant} x {portfolio-a,portfolio-b}.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
load_secrets
load_tofu_env
arctl_login
require gh; require git
gh auth status >/dev/null 2>&1 || die "gh not authenticated — run: gh auth login"

MODEL_NAME="${MODEL_NAME:-us.anthropic.claude-haiku-4-5-20251001-v1:0}"
GH_USER="$(gh api user -q .login)"
REPO_SLUG="${AGENT_REPO_SLUG:-${GH_USER}/agw-multi-account-agents}"
BRANCH="main"
REPO_URL="https://github.com/${REPO_SLUG}.git"

step "Scaffolding the base agent (arctl init, ADK) and making it Bedrock-capable"
PROJ="$LAB_ROOT/agentdemo"
if [[ ! -d "$PROJ" ]]; then
  ( cd "$LAB_ROOT" && arctl init agent agentdemo --framework adk --language python \
      --model-provider anthropic --model-name claude-haiku-4-5 ) >/dev/null
fi
python3 "$LAB_ROOT/templates/agentcore_multicloud_patch.py" "$PROJ" >/dev/null 2>&1 || true
grep -q MODEL_PROVIDER "$PROJ/agentdemo/agent.py" || die "multicloud patch did not apply"
ok "base agent ready"

step "Deriving the two personas (poet, quant)"
persona() { # persona <name> <description> <instruction>
  local name="$1" desc="$2" instr="$3" dir="$LAB_ROOT/agents/$1"
  rm -rf "$dir"; mkdir -p "$LAB_ROOT/agents"; cp -R "$PROJ" "$dir"
  rm -rf "$dir/.git" "$dir/mcp_server"
  NAME="$name" DESC="$desc" INSTR="$instr" python3 - "$dir/agentdemo/agent.py" <<'EOF'
import os, re, sys
p = sys.argv[1]
s = open(p).read()
s = s.replace('description="agentdemo agent."', f'description="{os.environ["DESC"]}"')
s = re.sub(r'instruction=build_instruction\("""[\s\S]*?"""\)',
           'instruction=build_instruction("""' + os.environ["INSTR"] + '""")', s)
open(p, "w").write(s)
EOF
  ok "persona $name derived"
}
persona poet "Dice poet: rolls dice and answers in short rhymes." \
  "You are a playful dice poet. Use the roll_die and check_prime tools when asked, and always answer in a short two-line rhyme that includes the numeric result."
persona quant "Dice quant: terse numeric answers only." \
  "You are a terse quantitative assistant. Use the roll_die and check_prime tools when asked. Answer with the bare numbers and one short factual sentence, no pleasantries."

step "Pushing the agents to the public repo ${REPO_SLUG}"
gh repo view "$REPO_SLUG" >/dev/null 2>&1 || gh repo create "$REPO_SLUG" --public >/dev/null
T="$(mktemp -d)"; cp -R "$LAB_ROOT/agents/poet" "$LAB_ROOT/agents/quant" "$T/"
( cd "$T" && git init -qb "$BRANCH" && git add -A \
  && git -c user.email=demo@local -c user.name=demo commit -qm "poet + quant agents" \
  && git remote add origin "https://x-access-token:$(gh auth token)@github.com/${REPO_SLUG}.git" \
  && git push -fq origin "$BRANCH" )
rm -rf "$T"
ok "source pushed to ${REPO_URL}@${BRANCH} (public: AgentCore clones with no token)"

step "Publishing the Agent records"
for A in poet quant; do
  DESC="$( [[ $A == poet ]] && echo 'Dice poet, rolls dice and answers in rhyme.' || echo 'Dice quant, terse numeric answers.' )"
  F="$(mktemp)"; cat > "$F" <<EOF
apiVersion: ar.dev/v1alpha1
kind: Agent
metadata: {name: ${A}}
spec:
  description: ${DESC}
  modelName: ${MODEL_NAME}
  modelProvider: bedrock
  source:
    repository: {url: ${REPO_URL}, branch: ${BRANCH}, subfolder: ${A}}
EOF
  arctl apply -f "$F"; rm -f "$F"
done
ok "Agents poet + quant published"

step "Deploying: {poet,quant} x {portfolio-a,portfolio-b}"
deploy() { # deploy <agent> <env> <region>
  local agent="$1" env="$2" region="$3"
  local F; F="$(mktemp)"; cat > "$F" <<EOF
apiVersion: ar.dev/v1alpha1
kind: Deployment
metadata: {name: ${agent}-${env}}
spec:
  targetRef: {kind: Agent, name: ${agent}}
  runtimeRef: {kind: Runtime, name: ${env}}
  runtimeConfig: {region: ${region}}
  env: {MODEL_PROVIDER: bedrock, AWS_REGION: ${region}, MODEL_NAME: ${MODEL_NAME}}
EOF
  arctl apply -f "$F"; rm -f "$F"
}
deploy poet  portfolio-a "$PORTFOLIO_A_REGION"
deploy quant portfolio-a "$PORTFOLIO_A_REGION"
deploy poet  portfolio-b "$PORTFOLIO_B_REGION"
deploy quant portfolio-b "$PORTFOLIO_B_REGION"
ok "4 deployments submitted — AgentCore provisions in the background (~2-4 min each)"
arctl get deployments 2>/dev/null | sed 's/^/  /' >&2 || true
echo "  Next: ./scripts/32-wait-runtimes.sh" >&2
