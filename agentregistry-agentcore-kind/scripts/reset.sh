#!/usr/bin/env bash
# reset.sh — put the demo back to the EXACT post-setup state, so the notebook
# runs from the top as if you'd just brought the cluster up and started the demo
# for the first time. Removes everything the notebook CREATES; keeps everything
# setup.sh established.
#
# REMOVES: the scaffolded agentdemo/ project, the agent catalog entry, the agent
# + MCP-server deployments on kagent (and the kagent Agent/MCPServer CRs + waypoints
# + AccessPolicies they spawn), and the deployed AgentCore agent runtime instance.
# KEEPS (platform, from setup.sh): kind cluster + Keycloak + kagent + Enterprise UI
# + arctl daemon; the published catalog (MCP servers + skills); BOTH connected
# runtimes (kind-kagent AND aws-agentcore); and the AWS platform wiring (the
# CloudFormation cross-account role + the agent ECR repo) — so the notebook's
# AgentCore step deploys cleanly against the existing platform with no re-connect.
#
# Set RESET_KEEP_AWS_PLATFORM=false to ALSO tear down the AWS platform (CF role,
# ECR repo, aws-agentcore runtime) — only if you intend to re-run 04d-connect-aws.
# For a FULL teardown (cluster, daemon, registry too) use ./scripts/cleanup.sh.
#
#   ./scripts/reset.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

cd "$LAB_ROOT"
arctl_login || true
export AWS_REGION="${AWS_REGION:-us-east-1}"

# Names the notebook/scripts use (override via env if you changed them).
AGENTS="${RESET_AGENTS:-agentdemo agentdemo-agentcore}"
# The notebook deploys the agent AND its MCP servers (each its own Deployment on
# a Kagent runtime). Remove all three so the next run re-creates them cleanly.
DEPLOYMENTS="${RESET_DEPLOYMENTS:-agentdemo agentdemo-agentcore everything-server my-mcp}"
AWS_RUNTIME_NAMES="${RESET_AWS_RUNTIMES:-agentdemo_agentcore}"
# Keep BOTH runtimes — kind-kagent AND aws-agentcore are platform connections
# registered by setup.sh (04b/04d), not demo artifacts. Default = keep them.
KEEP_AWS_PLATFORM="${RESET_KEEP_AWS_PLATFORM:-true}"
if [[ "$KEEP_AWS_PLATFORM" == "true" ]]; then
  AR_RUNTIMES="${RESET_AR_RUNTIMES:-}"            # keep aws-agentcore + kind-kagent
  ECR_REPOS="${RESET_ECR_REPOS:-}"                # keep the agent ECR repo (platform)
  DELETE_STACK=false                               # keep the CloudFormation role (platform)
else
  AR_RUNTIMES="${RESET_AR_RUNTIMES:-aws-agentcore}"
  ECR_REPOS="${RESET_ECR_REPOS:-agentdemo}"
  DELETE_STACK=true
fi
STACK_NAME="${STACK_NAME:-AgentRegistryAccess}"

have_aws() { command -v aws >/dev/null 2>&1 && aws sts get-caller-identity >/dev/null 2>&1; }

# ── 0. drop the AccessPolicy + waypoint label the notebook's step 10 adds ─────
if kubectl --context "$CTX" get ns kagent >/dev/null 2>&1; then
  step "Removing AccessPolicy + waypoint label"
  kc -n kagent delete accesspolicy --all >/dev/null 2>&1 && ok "AccessPolicies cleared" || true
  for m in $(kc -n kagent get mcpserver -o name 2>/dev/null); do
    kc -n kagent label "$m" kagent.solo.io/waypoint- >/dev/null 2>&1 || true
  done
fi

# ── 1. registry deployments (this also unwinds the kagent / AgentCore objects) ─
step "Deleting registry deployments"
for d in $DEPLOYMENTS; do
  arctl delete deployment "$d" >/dev/null 2>&1 && ok "deployment $d" || log "no deployment $d"
done

# ── 2. AWS AgentCore runtimes + CloudFormation + ECR ─────────────────────────
if have_aws; then
  # Export local AWS creds so the aws CLI below can delete the AgentCore runtime.
  creds="$(aws configure export-credentials --format env 2>/dev/null)" && eval "$creds" \
    && export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_REGION
  step "Deleting AWS AgentCore runtimes"
  for rn in $AWS_RUNTIME_NAMES; do
    rid="$(aws bedrock-agentcore-control list-agent-runtimes --region "$AWS_REGION" 2>/dev/null \
      | jq -r --arg n "$rn" '.agentRuntimes[]? | select(.agentRuntimeName==$n) | .agentRuntimeId')"
    if [[ -n "$rid" ]]; then aws bedrock-agentcore-control delete-agent-runtime --region "$AWS_REGION" --agent-runtime-id "$rid" >/dev/null 2>&1 && ok "AWS runtime $rn"; else log "no AWS runtime $rn"; fi
  done
  if [[ "$DELETE_STACK" == "true" ]]; then
    step "Deleting CloudFormation stack '$STACK_NAME'"
    if aws cloudformation describe-stacks --stack-name "$STACK_NAME" >/dev/null 2>&1; then
      aws cloudformation delete-stack --stack-name "$STACK_NAME" \
        && aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" 2>/dev/null \
        && ok "stack deleted" || warn "stack delete may still be in progress"
    else log "no stack $STACK_NAME"; fi
  else
    log "keeping CloudFormation role '$STACK_NAME' (platform; set RESET_KEEP_AWS_PLATFORM=false to remove)"
  fi
  step "Deleting ECR repos"
  for r in $ECR_REPOS; do
    aws ecr delete-repository --repository-name "$r" --force >/dev/null 2>&1 && ok "ECR $r" || log "no ECR repo $r"
  done
else
  warn "no live AWS session — skipping AWS cleanup (run 'aws sso login' to also clear AWS)"
fi

# ── 3. registry catalog entries + runtimes ───────────────────────────────────
step "Deleting catalog entries (the agent only — the MCP servers + skill are"
log "published once by setup.sh, like the kind-kagent runtime, so they stay)"
for a in $AGENTS; do arctl delete agent "$a" >/dev/null 2>&1 && ok "agent $a" || log "no agent $a"; done
step "Deleting registry runtimes"
for r in $AR_RUNTIMES; do arctl delete runtime "$r" >/dev/null 2>&1 && ok "runtime $r" || log "no runtime $r"; done

# ── 4. leftover kagent objects (in case the adapter left any) ────────────────
if kubectl --context "$CTX" get ns kagent >/dev/null 2>&1; then
  step "Sweeping leftover kagent objects"
  kc -n kagent delete agents.kagent.dev --all >/dev/null 2>&1 || true
  kc -n kagent delete mcpserver --all >/dev/null 2>&1 || true
  ok "kagent agents/mcpservers cleared"
fi

# ── 5. local scaffold + scratch ──────────────────────────────────────────────
# agentdemo/ sits at the lab root (next to demo.ipynb); .agentcore scratch
# lives at the lab root (LAB_ROOT).
step "Removing local scaffold + scratch"
rm -rf "$LAB_ROOT/agentdemo" "$LAB_ROOT/.agentcore"
ok "removed agentdemo/ and .agentcore/"

step "Reset complete — platform still up; re-run the notebook from the top"
echo "  (full teardown of the cluster/daemon/registry:  ./scripts/cleanup.sh)" >&2
