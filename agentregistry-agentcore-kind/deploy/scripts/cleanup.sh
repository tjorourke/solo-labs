#!/usr/bin/env bash
# cleanup.sh — tear down what the demo built. Two modes:
#
#   ./scripts/cleanup.sh            tear down EVERYTHING — AWS AgentCore bits
#   ./scripts/cleanup.sh all        first, then the local kind cluster, arctl
#                                   daemon, registry container and .agentcore/.
#   ./scripts/cleanup.sh agentcore  AWS only — undo what the AgentCore deploy made
#                                   (registry Deployment, BedrockAgentCore
#                                   runtime, CloudFormation stack, ECR repo).
#   ./scripts/cleanup.sh gcp        Google only — the agent's Vertex reasoning
#                                   engine, the Cloud Run MCP service, and the
#                                   deployer SA + custom roles (KEEP_GCP_SA=true
#                                   keeps the SA/roles).
#
# Each cloud path no-ops cleanly when that cloud was never set up (no AWS session /
# no GCP_PROJECT_ID), so `all` is safe regardless of which runtimes you deployed.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

# ── config (override via env) ────────────────────────────────────────────────
[ -f "$LAB_ROOT/.env.local" ] && { set -a; . "$LAB_ROOT/.env.local"; set +a; }  # GCP_PROJECT_ID / AWS_*
export AWS_REGION="${AWS_REGION:-us-east-1}"
AGENT_NAME="${AGENT_NAME:-agentdemo}"
AWS_RUNTIME_ID="${AWS_RUNTIME_ID:-aws-agentcore}"
STACK_NAME="${STACK_NAME:-AgentRegistryAccess}"
ECR_REPO_NAME="${ECR_REPO_NAME:-$AGENT_NAME}"
# Google Cloud (Vertex AI + Cloud Run) teardown config
GCP_PROJECT_ID="${GCP_PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
GCP_LOCATION="${GCP_LOCATION:-us-central1}"
GCP_RUNTIME_ID="${GCP_RUNTIME_ID:-gcp-vertex}"
GCP_MCP_SERVICE="${GCP_MCP_SERVICE:-my-mcp}"

# ── AWS AgentCore teardown ────────────────────────────────────────────────────
# No-ops (warn + skip) when there's no live AWS session, so it's safe to call
# unconditionally from the `all` path.
cleanup_agentcore() {
  step "Tearing down AWS Bedrock AgentCore bits"
  if ! command -v aws >/dev/null 2>&1; then
    warn "aws CLI not found — skipping AgentCore teardown"; return 0
  fi
  if ! aws sts get-caller-identity >/dev/null 2>&1; then
    warn "no live AWS session (aws sso login) — skipping AgentCore teardown"; return 0
  fi

  if command -v arctl >/dev/null 2>&1; then
    arctl_login
    log "deleting registry Deployment '${AGENT_NAME}-agentcore'"
    arctl delete deployment "${AGENT_NAME}-agentcore" >/dev/null 2>&1 || true
    log "deleting BedrockAgentCore runtime '$AWS_RUNTIME_ID'"
    arctl delete runtime "$AWS_RUNTIME_ID" >/dev/null 2>&1 || true
    ok "registry deployment + runtime removed"
  else
    warn "arctl not found — skipped registry deployment + runtime delete"
  fi

  log "deleting CloudFormation stack '$STACK_NAME'"
  if aws cloudformation describe-stacks --stack-name "$STACK_NAME" >/dev/null 2>&1; then
    aws cloudformation delete-stack --stack-name "$STACK_NAME" >/dev/null 2>&1 || true
    aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" >/dev/null 2>&1 || true
    ok "stack '$STACK_NAME' deleted"
  else
    log "stack '$STACK_NAME' not present"
  fi

  log "deleting ECR repo '$ECR_REPO_NAME'"
  aws ecr delete-repository --repository-name "$ECR_REPO_NAME" --force >/dev/null 2>&1 \
    && ok "ECR repo '$ECR_REPO_NAME' deleted" || log "ECR repo '$ECR_REPO_NAME' not present"
}

# ── Google Cloud teardown ─────────────────────────────────────────────────────
# No-ops (warn + skip) when gcloud is absent or the project is unreachable, so it's
# safe to call from `all` even if you never deployed to Google. Deletes the agent's
# Vertex reasoning engine + the Cloud Run MCP service, and the deployer SA + custom
# roles (set KEEP_GCP_SA=true to keep the SA/roles for re-deploys).
cleanup_gcp() {
  step "Tearing down Google Cloud (Vertex AI + Cloud Run) bits"
  command -v gcloud >/dev/null 2>&1 || { warn "gcloud not found — skipping GCP teardown"; return 0; }
  [ -n "$GCP_PROJECT_ID" ] || { log "no GCP_PROJECT_ID — skipping GCP teardown (nothing deployed to Google)"; return 0; }
  gcloud projects describe "$GCP_PROJECT_ID" >/dev/null 2>&1 \
    || { warn "no access to project '$GCP_PROJECT_ID' — skipping GCP teardown"; return 0; }
  log "project $GCP_PROJECT_ID / $GCP_LOCATION"
  local sa="agentregistry-deployer@${GCP_PROJECT_ID}.iam.gserviceaccount.com"

  # 1. registry-driven undeploy (the GCP adapter removes the engine + Cloud Run)
  if command -v arctl >/dev/null 2>&1; then
    arctl_login
    for d in "${AGENT_NAME}-gcp" "${GCP_MCP_SERVICE}-gcp"; do
      arctl delete deployment "$d" >/dev/null 2>&1 && ok "deleted registry deployment $d" || log "no registry deployment $d"
    done
    arctl delete runtime "$GCP_RUNTIME_ID" >/dev/null 2>&1 && ok "deleted runtime $GCP_RUNTIME_ID" || log "runtime $GCP_RUNTIME_ID not present"
  fi

  # 2. backstop: delete the Vertex reasoning engine named "$AGENT_NAME" (leave any
  #    others, e.g. a separately-created dice-agent).
  local tok eng
  tok="$(gcloud auth print-access-token 2>/dev/null)"
  if [ -n "$tok" ]; then
    eng="$(curl -s -H "Authorization: Bearer $tok" \
      "https://${GCP_LOCATION}-aiplatform.googleapis.com/v1/projects/${GCP_PROJECT_ID}/locations/${GCP_LOCATION}/reasoningEngines" 2>/dev/null \
      | AGENT="$AGENT_NAME" python3 -c "import sys,json,os
try:
    d=json.load(sys.stdin)
except Exception:
    d={}
for x in d.get('reasoningEngines',[]):
    if x.get('displayName')==os.environ['AGENT']: print(x['name'])" 2>/dev/null)"
    for e in $eng; do
      curl -s -X DELETE -H "Authorization: Bearer $tok" \
        "https://${GCP_LOCATION}-aiplatform.googleapis.com/v1/${e}?force=true" >/dev/null 2>&1 \
        && ok "deleting Vertex reasoning engine ${e##*/}" || log "could not delete engine ${e##*/} (an op may be in flight)"
    done
  fi

  # 3. backstop: delete the Cloud Run MCP service
  gcloud run services delete "$GCP_MCP_SERVICE" --project "$GCP_PROJECT_ID" --region "$GCP_LOCATION" --quiet >/dev/null 2>&1 \
    && ok "deleted Cloud Run service $GCP_MCP_SERVICE" || log "Cloud Run service $GCP_MCP_SERVICE not present"

  # 4. the deployer service account + custom roles (KEEP_GCP_SA=true to keep)
  if [ "${KEEP_GCP_SA:-false}" = "true" ]; then
    log "KEEP_GCP_SA=true — leaving the deployer SA + custom roles in place"
  else
    gcloud iam service-accounts delete "$sa" --project "$GCP_PROJECT_ID" --quiet >/dev/null 2>&1 \
      && ok "deleted service account $sa" || log "service account $sa not present"
    for r in AgentRegistrySecretManager AgentRegistryIAMManager; do
      gcloud iam roles delete "$r" --project "$GCP_PROJECT_ID" --quiet >/dev/null 2>&1 \
        && ok "deleted custom role $r" || log "custom role $r not present"
    done
  fi
}

# ── local teardown ────────────────────────────────────────────────────────────
cleanup_local() {
  step "Deleting kind cluster '$CLUSTER_NAME'"
  kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME" \
    && { kind delete cluster --name "$CLUSTER_NAME"; ok "deleted"; } || log "not present"
  step "Uninstalling the in-cluster AgentRegistry (best-effort; the cluster delete also removes it)"
  helm --kube-context "$CTX" uninstall agentregistry -n "$AR_NS" >/dev/null 2>&1 && ok "agentregistry uninstalled" || log "agentregistry not present"
  step "Removing the local registry container '$REG_NAME'"
  docker rm -f "$REG_NAME" >/dev/null 2>&1 && ok "registry removed" || log "registry not present"
  step "Removing the local .agentcore/ scratch dir"
  rm -rf "$LAB_ROOT/.agentcore" && ok ".agentcore/ removed"
}

case "${1:-all}" in
  agentcore)
    cleanup_agentcore
    step "Cleanup complete"
    log "AWS AgentCore bits removed (local cluster left running)"
    ;;
  gcp)
    cleanup_gcp
    step "Cleanup complete"
    log "Google Cloud bits removed (local cluster left running)"
    ;;
  all)
    cleanup_agentcore
    cleanup_gcp
    cleanup_local
    step "Cleanup complete"
    log "AWS + Google Cloud bits + local cluster, registry and .agentcore/ removed"
    ;;
  *) echo "Usage: $0 all | agentcore | gcp" >&2; exit 2;;
esac
