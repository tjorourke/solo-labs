#!/bin/bash
# Shared helpers for the agentgateway standalone HA lab.
#
# Source this, do not run it.

set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$LAB_DIR/terraform"

# OpenTofu or Terraform, whichever is installed.
TF="${TF:-}"
if [[ -z "$TF" ]]; then
  if command -v tofu >/dev/null 2>&1; then TF=tofu
  elif command -v terraform >/dev/null 2>&1; then TF=terraform
  fi
fi

c_red=$'\033[31m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'
c_blue=$'\033[34m'; c_bold=$'\033[1m'; c_off=$'\033[0m'

log()  { printf '%s==>%s %s\n' "$c_blue" "$c_off" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$c_green" "$c_off" "$*"; }
warn() { printf '%s warn%s %s\n' "$c_yellow" "$c_off" "$*" >&2; }
die()  { printf '%serror%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }
hdr()  { printf '\n%s%s%s\n' "$c_bold" "$*" "$c_off"; }

# ---------------------------------------------------------------------------
# This lab creates paid infrastructure. Force a conscious, explicit account
# choice: LAB_AWS_PROFILE wins over anything a sourced secrets file exported,
# because sourcing a secrets file can silently change which account you are
# pointing at.
# ---------------------------------------------------------------------------
require_aws() {
  [[ -n "${LAB_AWS_PROFILE:-}" ]] \
    || die "set LAB_AWS_PROFILE=<aws profile for this lab> (it overrides any AWS_PROFILE from a secrets file)"
  export AWS_PROFILE="$LAB_AWS_PROFILE"
  export AWS_REGION="${LAB_AWS_REGION:-us-east-1}"
  export AWS_DEFAULT_REGION="$AWS_REGION"
  aws sts get-caller-identity >/dev/null 2>&1 \
    || die "AWS credentials are not working for profile '$AWS_PROFILE' (try: aws sso login --profile $AWS_PROFILE)"
  log "AWS profile: $AWS_PROFILE   region: $AWS_REGION"
}

require_tools() {
  local missing=()
  for t in aws jq curl; do command -v "$t" >/dev/null 2>&1 || missing+=("$t"); done
  [[ -n "$TF" ]] || missing+=("tofu or terraform")
  (( ${#missing[@]} == 0 )) || die "missing required tools: ${missing[*]}"
}

tf() { (cd "$TF_DIR" && "$TF" "$@"); }

tf_out() { (cd "$TF_DIR" && "$TF" output -raw "$1" 2>/dev/null); }

require_stack() {
  [[ -f "$TF_DIR/terraform.tfstate" ]] || die "no state found; run scripts/01-apply.sh first"
  GATEWAY_URL="$(tf_out gateway_url)"
  [[ -n "$GATEWAY_URL" ]] || die "could not read the gateway_url output; is the stack applied?"
  export GATEWAY_URL
}

# ---------------------------------------------------------------------------
# Tokens. Every negative test in this lab uses a real token minted here rather
# than a hand-edited JWT, so a refusal is the gateway's decision and not a
# malformed input.
# ---------------------------------------------------------------------------

# mint_token <client: all|llm-only> [scopes]
mint_token() {
  local which="${1:-all}" scopes="${2:-}"
  local token_url audience cid csec
  token_url="$(tf_out cognito_token_url)"
  audience="$(tf_out cognito_api_audience)"

  if [[ "$which" == "llm-only" ]]; then
    cid="$(tf_out cognito_m2m_llm_only_client_id)"
    csec="$(tf_out cognito_m2m_llm_only_client_secret)"
    scopes="${scopes:-$audience/llm.invoke}"
  else
    cid="$(tf_out cognito_m2m_client_id)"
    csec="$(tf_out cognito_m2m_client_secret)"
    scopes="${scopes:-$audience/llm.invoke $audience/mcp.call $audience/admin}"
  fi

  local resp
  resp="$(curl -s -u "$cid:$csec" \
    -d "grant_type=client_credentials" \
    --data-urlencode "scope=$scopes" \
    "$token_url")"
  local tok
  tok="$(echo "$resp" | jq -r '.access_token // empty')"
  [[ -n "$tok" ]] || die "could not mint a token: $resp"
  echo "$tok"
}

# Decode a JWT payload for display. Nothing is verified here; this is for reading.
jwt_payload() {
  local p="${1#*.}"; p="${p%%.*}"
  local pad=$(( ${#p} % 4 ))
  (( pad )) && p="$p$(printf '=%.0s' $(seq $((4-pad))))"
  echo "$p" | tr '_-' '/+' | base64 -d 2>/dev/null | jq .
}

# ---------------------------------------------------------------------------
# Fleet helpers
# ---------------------------------------------------------------------------

# Instance ids in the Auto Scaling group, one per line.
fleet_instances() {
  local asg; asg="$(tf_out autoscaling_group_name)"
  aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$asg" \
    --query 'AutoScalingGroups[0].Instances[].InstanceId' --output text | tr '\t' '\n'
}

# instance id, availability zone, private ip, lifecycle state
fleet_table() {
  local asg; asg="$(tf_out autoscaling_group_name)"
  local ids; ids="$(fleet_instances | tr '\n' ' ')"
  [[ -n "${ids// /}" ]] || { echo "(no instances)"; return; }
  aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$asg" \
    --query 'AutoScalingGroups[0].Instances[].[InstanceId,AvailabilityZone,LifecycleState,HealthStatus]' \
    --output text | column -t
}

# Healthy/unhealthy counts in the ALB target group.
target_health() {
  local tg
  tg="$(aws elbv2 describe-target-groups --names "$(tf_out autoscaling_group_name)-gw" \
        --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null)" || return 1
  aws elbv2 describe-target-health --target-group-arn "$tg" \
    --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output text | column -t
}

healthy_count() {
  target_health 2>/dev/null | awk '$2=="healthy"' | wc -l | tr -d ' '
}

# Run a shell command on one node over SSM and print its output.
#
# The command is passed as JSON built by jq rather than interpolated into the
# --parameters string, so quotes, pipes and backslashes in the command survive.
node_exec() {
  local id="$1"; shift
  local payload cid status
  payload="$(mktemp)"
  jq -nc --arg c "$*" '{commands: [$c]}' > "$payload"

  cid="$(aws ssm send-command \
    --instance-ids "$id" \
    --document-name AWS-RunShellScript \
    --parameters "file://$payload" \
    --query 'Command.CommandId' --output text 2>/dev/null)" || { rm -f "$payload"; return 1; }
  rm -f "$payload"
  [[ -n "$cid" && "$cid" != "None" ]] || return 1

  for _ in $(seq 1 90); do
    status="$(aws ssm get-command-invocation --command-id "$cid" --instance-id "$id" \
      --query 'Status' --output text 2>/dev/null || echo Pending)"
    case "$status" in
      Success)
        aws ssm get-command-invocation --command-id "$cid" --instance-id "$id" \
          --query 'StandardOutputContent' --output text
        return 0 ;;
      Failed|Cancelled|TimedOut)
        aws ssm get-command-invocation --command-id "$cid" --instance-id "$id" \
          --query 'StandardErrorContent' --output text >&2
        return 1 ;;
    esac
    sleep 2
  done
  warn "SSM command on $id did not finish in time"
  return 1
}

# node_exec with failures reduced to empty output, for display loops that should not
# take the whole script down with them.
node_try() { node_exec "$@" 2>/dev/null || true; }

# Which node answered? /whoami is served in-process by every node.
whoami_node() {
  curl -s --max-time 10 "$GATEWAY_URL/whoami" | jq -r '.node // "?"'
}

# Wait until the gateway answers, or give up.
wait_for_gateway() {
  local tries="${1:-60}"
  for _ in $(seq 1 "$tries"); do
    if curl -sf --max-time 5 -o /dev/null "$GATEWAY_URL/whoami"; then return 0; fi
    sleep 5
  done
  return 1
}

# ---------------------------------------------------------------------------
# Assertions, so a demo script fails loudly rather than looking like it passed.
# ---------------------------------------------------------------------------
PASS=0; FAIL=0

expect() { # expect <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    printf '%s  ok%s %-56s %s\n' "$c_green" "$c_off" "$1" "$3"; PASS=$((PASS+1))
  else
    printf '%sFAIL%s %-56s expected %s, got %s\n' "$c_red" "$c_off" "$1" "$2" "$3"; FAIL=$((FAIL+1))
  fi
}

expect_contains() { # expect_contains <label> <needle> <haystack>
  if [[ "$3" == *"$2"* ]]; then
    printf '%s  ok%s %-56s contains %s\n' "$c_green" "$c_off" "$1" "$2"; PASS=$((PASS+1))
  else
    printf '%sFAIL%s %-56s expected to contain %s\n' "$c_red" "$c_off" "$1" "$2"; FAIL=$((FAIL+1))
    printf '     got: %s\n' "${3:0:300}"
  fi
}

summary() {
  hdr "passed $PASS, failed $FAIL"
  (( FAIL == 0 )) || exit 1
}

code() { curl -s -o /dev/null -w '%{http_code}' --max-time 30 "$@"; }
