#!/usr/bin/env bash
# 32-wait-runtimes.sh — wait for the four AgentCore runtimes (two per account)
# to reach READY and capture their ARNs into deploy/.env.runtimes for the
# gateway backends. Polls each account under its AgentRegistryAccess role
# (assumed with the ar-control-plane user + ExternalId), the same identity the
# registry itself uses — the operator's own role in portfolio B deliberately
# has no bedrock-agentcore permissions.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
load_tofu_env

assume_env() { # assume_env <role-arn> <external-id> — exports temp creds
  local out
  out="$(AWS_ACCESS_KEY_ID="$AR_AWS_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$AR_AWS_SECRET_ACCESS_KEY" AWS_SESSION_TOKEN= \
    aws sts assume-role --role-arn "$1" --external-id "$2" \
      --role-session-name lab-wait --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text)"
  export AWS_ACCESS_KEY_ID="$(awk '{print $1}' <<<"$out")"
  export AWS_SECRET_ACCESS_KEY="$(awk '{print $2}' <<<"$out")"
  export AWS_SESSION_TOKEN="$(awk '{print $3}' <<<"$out")"
}

# runtime_arn <region> <name-substring> — print the READY runtime ARN, or empty
runtime_arn() {
  aws bedrock-agentcore-control list-agent-runtimes --region "$1" 2>/dev/null \
    | jq -r --arg n "$2" '.agentRuntimes[]? | select((.agentRuntimeName|ascii_downcase|contains($n)) and .status=="READY") | .agentRuntimeArn' | head -1
}

ENVF="$LAB_ROOT/deploy/.env.runtimes"
: > "$ENVF"; chmod 600 "$ENVF"
declare -a MISSING

wait_env() { # wait_env <env> <role> <extid> <region>
  local env="$1" role="$2" extid="$3" region="$4" a q i
  step "Waiting for READY runtimes in ${env} (${region})"
  ( assume_env "$role" "$extid"
    for i in $(seq 1 60); do
      a="$(runtime_arn "$region" poet)"; q="$(runtime_arn "$region" quant)"
      [[ -n "$a" && -n "$q" ]] && break
      log "[${i}] poet: ${a:-pending} · quant: ${q:-pending}"; sleep 15
    done
    [[ -n "$a" && -n "$q" ]] || { warn "runtimes not READY in ${env} after 15m"; \
      aws bedrock-agentcore-control list-agent-runtimes --region "$region" 2>/dev/null | jq -r '.agentRuntimes[]? | "\(.agentRuntimeName) \(.status)"' | sed 's/^/    /' >&2; exit 1; }
    UPPER="$(tr '[:lower:]-' '[:upper:]_' <<<"$env")"
    { echo "${UPPER}_POET_ARN=${a}"; echo "${UPPER}_QUANT_ARN=${q}"; } >> "$ENVF"
    ok "${env}: poet + quant READY"
  ) || MISSING+=("$env")
}

wait_env portfolio-a "$PORTFOLIO_A_AR_ROLE_ARN" "$PORTFOLIO_A_EXTERNAL_ID" "$PORTFOLIO_A_REGION"
wait_env portfolio-b "$PORTFOLIO_B_AR_ROLE_ARN" "$PORTFOLIO_B_EXTERNAL_ID" "$PORTFOLIO_B_REGION"

[[ ${#MISSING[@]} -eq 0 ]] || die "environments not ready: ${MISSING[*]} — check 'arctl get deployments' and the registry server logs"
step "All four runtime ARNs captured"
sed 's/^/  /' "$ENVF" >&2
echo "  Next: ./scripts/40-gateway-config.sh" >&2
