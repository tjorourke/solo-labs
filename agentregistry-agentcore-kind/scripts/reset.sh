#!/usr/bin/env bash
# reset.sh — put the demo back to the EXACT post-setup state, so the notebook
# runs from the top as if you'd just brought the cluster up and started the demo
# for the first time. Removes everything the notebook CREATES; keeps everything
# setup.sh established.
#
# REMOVES: the scaffolded agentdemo/ project, the agent catalog entry, the agent
# + MCP-server deployments across ALL runtimes (kagent objects + waypoints +
# AccessPolicies they spawn), the deployed AgentCore agent runtime instance, and
# the deployed Google bits (the Vertex AI reasoning engine + the Cloud Run MCP).
# KEEPS (platform, from setup.sh): kind cluster + Keycloak + kagent + Enterprise UI
# + arctl daemon; the published catalog (MCP servers + skills); ALL connected
# runtimes (kind-kagent, aws-agentcore, gcp-vertex); the AWS platform wiring (the
# CloudFormation role + agent ECR repo); and the GCP platform wiring (the deployer
# service account + custom roles) — so the next demo redeploys to every runtime
# with no re-connect.
#
# Set RESET_KEEP_AWS_PLATFORM=false to ALSO tear down the AWS platform (CF role,
# ECR repo, aws-agentcore runtime), or RESET_KEEP_GCP_PLATFORM=false to tear down
# the GCP platform (gcp-vertex runtime + deployer SA/roles). For a FULL teardown
# (cluster, registry too) use ./scripts/cleanup.sh.
#
#   ./scripts/reset.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

cd "$LAB_ROOT"
arctl_login || true
[ -f "$LAB_ROOT/.env.local" ] && { set -a; . "$LAB_ROOT/.env.local"; set +a; }  # GCP_PROJECT_ID / AWS_*
export AWS_REGION="${AWS_REGION:-us-east-1}"

# Names the notebook/scripts use (override via env if you changed them).
AGENTS="${RESET_AGENTS:-agentdemo agentdemo-agentcore}"
# The notebook deploys the agent AND its MCP servers across runtimes (each its own
# Deployment). Remove them all so the next run re-creates them cleanly.
DEPLOYMENTS="${RESET_DEPLOYMENTS:-agentdemo agentdemo-agentcore agentdemo-gcp everything-server my-mcp my-mcp-gcp}"
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

# Google Cloud (Vertex AI + Cloud Run). Like AWS, keep the platform by default
# (the gcp-vertex runtime + deployer SA/roles); just remove the deployed agent
# engine + Cloud Run MCP so the next demo redeploys clean.
GCP_PROJECT_ID="${GCP_PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
GCP_LOCATION="${GCP_LOCATION:-us-central1}"
GCP_MCP_SERVICE="${GCP_MCP_SERVICE:-my-mcp}"
KEEP_GCP_PLATFORM="${RESET_KEEP_GCP_PLATFORM:-true}"

have_aws() { command -v aws >/dev/null 2>&1 && aws sts get-caller-identity >/dev/null 2>&1; }
have_gcp() { command -v gcloud >/dev/null 2>&1 && [ -n "$GCP_PROJECT_ID" ] && gcloud projects describe "$GCP_PROJECT_ID" >/dev/null 2>&1; }

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

# ── 2b. Google Cloud: Vertex reasoning engine + Cloud Run MCP ────────────────
if have_gcp; then
  tok="$(gcloud auth print-access-token 2>/dev/null)"
  step "Deleting the Google Vertex reasoning engine (agentdemo) + Cloud Run MCP"
  if [ -n "$tok" ]; then
    eng="$(curl -s -H "Authorization: Bearer $tok" \
      "https://${GCP_LOCATION}-aiplatform.googleapis.com/v1/projects/${GCP_PROJECT_ID}/locations/${GCP_LOCATION}/reasoningEngines" 2>/dev/null \
      | AGENT="agentdemo" python3 -c "import sys,json,os
try:
    d=json.load(sys.stdin)
except Exception:
    d={}
for x in d.get('reasoningEngines',[]):
    if x.get('displayName')==os.environ['AGENT']: print(x['name'])" 2>/dev/null)"
    for e in $eng; do
      curl -s -X DELETE -H "Authorization: Bearer $tok" \
        "https://${GCP_LOCATION}-aiplatform.googleapis.com/v1/${e}?force=true" >/dev/null 2>&1 \
        && ok "Vertex engine ${e##*/}" || log "engine ${e##*/} (an op may be in flight)"
    done
  fi
  gcloud run services delete "$GCP_MCP_SERVICE" --project "$GCP_PROJECT_ID" --region "$GCP_LOCATION" --quiet >/dev/null 2>&1 \
    && ok "Cloud Run $GCP_MCP_SERVICE" || log "no Cloud Run $GCP_MCP_SERVICE"
  if [[ "$KEEP_GCP_PLATFORM" == "true" ]]; then
    log "keeping gcp-vertex runtime + deployer SA/roles (platform; RESET_KEEP_GCP_PLATFORM=false to remove)"
  else
    arctl delete runtime gcp-vertex >/dev/null 2>&1 && ok "runtime gcp-vertex" || true
    gcloud iam service-accounts delete "agentregistry-deployer@${GCP_PROJECT_ID}.iam.gserviceaccount.com" --project "$GCP_PROJECT_ID" --quiet >/dev/null 2>&1 && ok "deployer SA" || true
    for r in AgentRegistrySecretManager AgentRegistryIAMManager; do
      gcloud iam roles delete "$r" --project "$GCP_PROJECT_ID" --quiet >/dev/null 2>&1 && ok "role $r" || true
    done
  fi
else
  warn "no GCP project/access — skipping Google cleanup (set GCP_PROJECT_ID + 'gcloud auth login' to also clear Google)"
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
