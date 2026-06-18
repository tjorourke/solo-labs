#!/usr/bin/env bash
# 03-aws-profiles.sh — create one AWS *application inference profile* per team,
# each copied from the base model's system profile and tagged for cost
# allocation (team=<name>). Writes results/profiles.env mapping team -> ARN.
#
# Application inference profiles are the unit AWS attributes cost to. The tag is
# what surfaces the team in Cost Explorer / the Cost and Usage Report. The ARN
# is what clients send as the model and what agentgateway stamps onto metrics.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
require_aws
mkdir -p "$RESULTS_DIR"

step "Resolving the base system inference profile for $BASE_MODEL ($REGION)"
# Prefer the system profile owned by the caller's OWN account. Some regions also
# expose AWS-managed cross-region profiles (a different account id in the ARN);
# copying an application profile from one of those lands it out-of-account and it
# can't be invoked. Pin to our account id, fall back to any match.
ACCT="$(aws sts get-caller-identity --query Account --output text)"
SYSTEM_ARN="$(aws bedrock list-inference-profiles --region "$REGION" --type-equals SYSTEM_DEFINED \
  --query "inferenceProfileSummaries[?inferenceProfileId=='${BASE_MODEL}' && contains(inferenceProfileArn, ':${ACCT}:')].inferenceProfileArn | [0]" \
  --output text)"
if [[ -z "$SYSTEM_ARN" || "$SYSTEM_ARN" == "None" ]]; then
  SYSTEM_ARN="$(aws bedrock list-inference-profiles --region "$REGION" --type-equals SYSTEM_DEFINED \
    --query "inferenceProfileSummaries[?inferenceProfileId=='${BASE_MODEL}'].inferenceProfileArn | [0]" --output text)"
fi
[[ -z "$SYSTEM_ARN" || "$SYSTEM_ARN" == "None" ]] && die "no system profile for $BASE_MODEL in $REGION (check model access)"
ok "base system profile: $SYSTEM_ARN"

: > "$RESULTS_DIR/profiles.env"
echo "SYSTEM_ARN=\"$SYSTEM_ARN\"" >> "$RESULTS_DIR/profiles.env"

for team in $TEAMS; do
  name="agw-cost-${team}"
  step "Application inference profile for team '$team'"
  arn="$(aws bedrock list-inference-profiles --region "$REGION" --type-equals APPLICATION \
    --query "inferenceProfileSummaries[?inferenceProfileName=='${name}'].inferenceProfileArn | [0]" \
    --output text 2>/dev/null || true)"
  if [[ -z "$arn" || "$arn" == "None" ]]; then
    arn="$(aws bedrock create-inference-profile --region "$REGION" \
      --inference-profile-name "$name" \
      --description "per team cost profiling for team $team" \
      --model-source "copyFrom=${SYSTEM_ARN}" \
      --tags key=team,value="$team" key=cost-center,value="$team" \
      --query 'inferenceProfileArn' --output text)"
    ok "created: $arn"
  else
    log "reusing existing: $arn"
  fi
  # results var name: TEAM_<TEAM>_ARN (upper, dashes->underscores)
  var="TEAM_$(echo "$team" | tr 'a-z-' 'A-Z_')_ARN"
  echo "${var}=\"$arn\"" >> "$RESULTS_DIR/profiles.env"
done

ok "wrote $RESULTS_DIR/profiles.env"; cat "$RESULTS_DIR/profiles.env" >&2
echo "  Next: ./scripts/04-backend.sh" >&2
