#!/usr/bin/env bash
# 33-model-access.sh — one-time per account: make the Bedrock Anthropic model
# invocable. A fresh AWS account cannot call Anthropic models until the
# use-case form is submitted and the model agreement is created; AgentCore
# agents then fail with "Model use case details have not been submitted".
# Runs under each account's AgentRegistryAccess role (tofu grants it the
# model-access management actions). Idempotent: skips accounts already
# AVAILABLE.
#
# The form schema is undocumented and picky: single-base64 JSON with
# intendedUsers as an ENUM STRING ("0" = internal employees) — the CLI
# base64-encodes the blob itself, so pass raw JSON.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
load_tofu_env

MODEL_ID="${MODEL_BASE_ID:-anthropic.claude-haiku-4-5-20251001-v1:0}"
FORM_JSON="${FORM_JSON:-{\"companyName\":\"${FORM_COMPANY:-Solo.io}\",\"companyWebsite\":\"${FORM_WEBSITE:-https://solo.io}\",\"intendedUsers\":\"0\",\"industryOption\":\"Software as a Service\",\"otherIndustryOption\":\"\",\"useCases\":\"Internal engineering validation of an AI gateway lab: demo agents on Bedrock AgentCore invoked through agentgateway.\"}}"

ensure_model_access() { # ensure_model_access <env> <role> <extid> <region>
  local env="$1" role="$2" extid="$3" region="$4"
  step "Model access in ${env} (${region})"
  ( out="$(AWS_ACCESS_KEY_ID="$AR_AWS_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$AR_AWS_SECRET_ACCESS_KEY" AWS_SESSION_TOKEN= \
      aws sts assume-role --role-arn "$role" --external-id "$extid" \
      --role-session-name model-access --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text)"
    export AWS_ACCESS_KEY_ID="$(awk '{print $1}' <<<"$out")" AWS_SECRET_ACCESS_KEY="$(awk '{print $2}' <<<"$out")" AWS_SESSION_TOKEN="$(awk '{print $3}' <<<"$out")"
    S="$(aws bedrock get-foundation-model-availability --region "$region" --model-id "$MODEL_ID" --query agreementAvailability.status --output text 2>/dev/null)"
    if [[ "$S" == "AVAILABLE" ]]; then ok "${env}: agreement already AVAILABLE"; exit 0; fi
    log "agreement status: ${S:-unknown} — submitting the use-case form"
    aws bedrock put-use-case-for-model-access --region "$region" --form-data "$FORM_JSON" >/dev/null
    OFFER="$(aws bedrock list-foundation-model-agreement-offers --region "$region" --model-id "$MODEL_ID" --query 'offers[0].offerToken' --output text)"
    aws bedrock create-foundation-model-agreement --region "$region" --model-id "$MODEL_ID" --offer-token "$OFFER" >/dev/null
    for _ in $(seq 1 40); do
      S="$(aws bedrock get-foundation-model-availability --region "$region" --model-id "$MODEL_ID" --query agreementAvailability.status --output text 2>/dev/null)"
      [[ "$S" == "AVAILABLE" ]] && break; log "agreement ${S} — waiting"; sleep 20
    done
    [[ "$S" == "AVAILABLE" ]] && ok "${env}: agreement AVAILABLE" || die "${env}: agreement still ${S} after 13m"
  )
}

ensure_model_access portfolio-a "$PORTFOLIO_A_AR_ROLE_ARN" "$PORTFOLIO_A_EXTERNAL_ID" "$PORTFOLIO_A_REGION"
ensure_model_access portfolio-b "$PORTFOLIO_B_AR_ROLE_ARN" "$PORTFOLIO_B_EXTERNAL_ID" "$PORTFOLIO_B_REGION"
echo "  Next: ./scripts/40-gateway-config.sh (or re-run ./scripts/41-invoke.sh)" >&2
