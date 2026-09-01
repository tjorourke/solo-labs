#!/usr/bin/env bash
# quick.sh — one-shot orchestrator.
#   up        provision AWS (tofu) + kind platform + runtimes + agents + gateway config + invoke
#   teardown  delete the kind cluster, the 4 AgentCore runtimes, and tofu destroy both accounts
#   status    what's running where
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

usage(){ echo "usage: $0 up|teardown|status" >&2; exit 1; }

delete_agentcore_runtimes() { # under each account's AgentRegistryAccess role
  load_tofu_env || return 0
  for spec in "a:$PORTFOLIO_A_AR_ROLE_ARN:$PORTFOLIO_A_EXTERNAL_ID:$PORTFOLIO_A_REGION" \
              "b:$PORTFOLIO_B_AR_ROLE_ARN:$PORTFOLIO_B_EXTERNAL_ID:$PORTFOLIO_B_REGION"; do
    IFS=: read -r env role extid region <<<"$spec"
    ( out="$(AWS_ACCESS_KEY_ID="$AR_AWS_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$AR_AWS_SECRET_ACCESS_KEY" AWS_SESSION_TOKEN= \
        aws sts assume-role --role-arn "$role" --external-id "$extid" \
        --role-session-name lab-teardown --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text 2>/dev/null)" || exit 0
      export AWS_ACCESS_KEY_ID="$(awk '{print $1}' <<<"$out")" AWS_SECRET_ACCESS_KEY="$(awk '{print $2}' <<<"$out")" AWS_SESSION_TOKEN="$(awk '{print $3}' <<<"$out")"
      for id in $(aws bedrock-agentcore-control list-agent-runtimes --region "$region" 2>/dev/null | jq -r '.agentRuntimes[]?.agentRuntimeId'); do
        aws bedrock-agentcore-control delete-agent-runtime --region "$region" --agent-runtime-id "$id" >/dev/null 2>&1 \
          && log "deleted AgentCore runtime $id (portfolio-$env)"
      done )
  done
}

case "${1:-}" in
  up)
    require_secrets
    "$SCRIPT_DIR/10-tofu.sh"
    "$SCRIPT_DIR/20-cluster.sh"
    "$SCRIPT_DIR/21-keycloak.sh"
    "$SCRIPT_DIR/22-agentgateway.sh"
    "$SCRIPT_DIR/23-ingress.sh"
    "$SCRIPT_DIR/24-agentregistry.sh"
    "$SCRIPT_DIR/30-runtimes.sh"
    "$SCRIPT_DIR/33-model-access.sh"
    "$SCRIPT_DIR/31-agents.sh"
    "$SCRIPT_DIR/32-wait-runtimes.sh"
    "$SCRIPT_DIR/40-gateway-config.sh"
    "$SCRIPT_DIR/41-invoke.sh"
    step "Lab is up"
    echo "  AgentRegistry : http://${AR_HOST}" >&2
    echo "  Agents        : http://${AGENTS_HOST}/portfolio-{a,b}/{poet,quant}" >&2
    echo "  Evidence      : PROFILE_A=... PROFILE_B=... ./scripts/50-cloudtrail.sh" >&2
    ;;
  teardown)
    step "Deleting the AgentCore runtimes in both accounts"
    delete_agentcore_runtimes
    step "Deleting the kind cluster"
    kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 || true
    ok "cluster deleted"
    step "tofu destroy (both accounts)"
    ( cd "$LAB_ROOT/tofu" && tofu destroy -input=false -auto-approve ) \
      && ok "AWS IAM destroyed" || warn "tofu destroy failed — retry manually in $LAB_ROOT/tofu"
    warn "S3 source-bundle buckets (bedrock-agentcore-codebuild-sources-*) are retained by design — empty + delete manually if wanted"
    ;;
  status)
    kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME" && ok "kind cluster '$CLUSTER_NAME' running" || warn "kind cluster not running"
    kc -n "$GW_NS" get gateway "$GW_NAME" 2>/dev/null | sed 's/^/  /' >&2 || true
    ARCTL_API_BASE_URL="$ARCTL_API_BASE_URL" arctl get deployments 2>/dev/null | sed 's/^/  /' >&2 || true
    [[ -f "$LAB_ROOT/deploy/.env.runtimes" ]] && sed 's/=.*arn/=arn/; s/^/  /' "$LAB_ROOT/deploy/.env.runtimes" >&2 || true
    ;;
  *) usage ;;
esac
