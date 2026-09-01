#!/usr/bin/env bash
# 50-cloudtrail.sh — the audit evidence: in EACH portfolio account, CloudTrail
# shows the gateway's AssumeRole into that account's invoke role with
# roleSessionName = the caller's Keycloak username. Looks events up under each
# account's AgentRegistryAccess role (tofu grants cloudtrail:LookupEvents), so
# no operator profile is needed. CloudTrail delivery lags 5-15 min after the
# invokes, so this polls.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
load_tofu_env

show_events() { # show_events <region> <invoke-role-name> — under current creds
  aws cloudtrail lookup-events --region "$1" \
    --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRole \
    --max-results 50 --output json 2>/dev/null \
  | jq -r --arg role "$2" '
      .Events[]
      | (.CloudTrailEvent | fromjson) as $e
      | select(($e.requestParameters.roleArn // "") | contains($role))
      | "\(.EventTime)  session=\($e.requestParameters.roleSessionName)  by=\($e.userIdentity.arn // $e.userIdentity.type)"' \
  | head -5 || true
}

check_env() { # check_env <env> <role> <extid> <region> <invoke-role-name>
  local env="$1" role="$2" extid="$3" region="$4" invoke="$5"
  step "Portfolio ${env} (${region}) — AssumeRole events into ${invoke}"
  ( out="$(AWS_ACCESS_KEY_ID="$AR_AWS_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$AR_AWS_SECRET_ACCESS_KEY" AWS_SESSION_TOKEN= \
      aws sts assume-role --role-arn "$role" --external-id "$extid" \
      --role-session-name cloudtrail-evidence --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text)"
    export AWS_ACCESS_KEY_ID="$(awk '{print $1}' <<<"$out")" AWS_SECRET_ACCESS_KEY="$(awk '{print $2}' <<<"$out")" AWS_SESSION_TOKEN="$(awk '{print $3}' <<<"$out")"
    FOUND=""
    for i in $(seq 1 40); do
      FOUND="$(show_events "$region" "$invoke")"
      [[ -n "$FOUND" ]] && break
      log "[${i}/40] no events yet (CloudTrail delivery lags) — retrying in 30s"
      sleep 30
    done
    if [[ -n "$FOUND" ]]; then
      printf '%s\n' "$FOUND" | sed 's/^/  /' >&2
      ok "portfolio ${env}: gateway AssumeRole in CloudTrail with the caller's session name"
    else
      warn "portfolio ${env}: no AssumeRole events for ${invoke} after 20m"
      exit 1
    fi )
}

check_env a "$PORTFOLIO_A_AR_ROLE_ARN" "$PORTFOLIO_A_EXTERNAL_ID" "$PORTFOLIO_A_REGION" agw-invoke-agentcore-portfolio-a
check_env b "$PORTFOLIO_B_AR_ROLE_ARN" "$PORTFOLIO_B_EXTERNAL_ID" "$PORTFOLIO_B_REGION" agw-invoke-agentcore-portfolio-b
