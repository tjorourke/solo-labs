#!/usr/bin/env bash
# cleanup.sh — tear down what the demo built. Two modes:
#
#   ./scripts/cleanup.sh            tear down EVERYTHING — AWS AgentCore bits
#   ./scripts/cleanup.sh all        first, then the local kind cluster, arctl
#                                   daemon, registry container and .agentcore/.
#   ./scripts/cleanup.sh agentcore  AWS only — undo what 08-agentcore.sh created
#                                   (registry Deployment, BedrockAgentCore
#                                   runtime, CloudFormation stack, ECR repo).
#
# The agentcore path no-ops cleanly when there's no live AWS session, so `all`
# is safe to run even if you never deployed to AWS. Honors the same env
# defaults as 08-agentcore.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

# ── config (override via env) ────────────────────────────────────────────────
export AWS_REGION="${AWS_REGION:-us-east-1}"
AGENT_NAME="${AGENT_NAME:-summarizer}"
AWS_RUNTIME_ID="${AWS_RUNTIME_ID:-aws-agentcore}"
STACK_NAME="${STACK_NAME:-AgentRegistryAccess}"
ECR_REPO_NAME="${ECR_REPO_NAME:-$AGENT_NAME}"

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
    arctl_token
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

# ── local teardown ────────────────────────────────────────────────────────────
cleanup_local() {
  step "Deleting kind cluster '$CLUSTER_NAME'"
  kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME" \
    && { kind delete cluster --name "$CLUSTER_NAME"; ok "deleted"; } || log "not present"
  step "Stopping the arctl daemon"
  arctl daemon stop >/dev/null 2>&1 && ok "daemon stopped" || log "daemon not running"
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
  all)
    cleanup_agentcore
    cleanup_local
    step "Cleanup complete"
    log "AWS AgentCore bits + local cluster, daemon, registry and .agentcore/ removed"
    ;;
  *) echo "Usage: $0 all | agentcore" >&2; exit 2;;
esac
