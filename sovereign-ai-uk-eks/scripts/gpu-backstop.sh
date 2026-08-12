#!/usr/bin/env bash
# Nightly forced scale-to-zero on the GPU nodegroup, so the $5.84/hr cannot be left
# running by accident.
#
#   ./scripts/gpu-backstop.sh arm      create the schedule (default 21:00 UTC daily)
#   ./scripts/gpu-backstop.sh disarm   DO THIS ON WEBINAR DAY
#   ./scripts/gpu-backstop.sh status   armed or not, and when it next fires
#   ./scripts/gpu-backstop.sh remove   delete the schedule and its role
#
#   HOUR_UTC=23 ./scripts/gpu-backstop.sh arm     override the time
#
# READ THIS BEFORE ARMING IT.
#
# This exists because a stated intention to run `gpu.sh down` is not a guardrail. It is
# also a loaded gun pointed at the demo: if it fires during a late rehearsal or during
# the webinar itself, it pulls the GPU out from under a live audience. Nothing about
# EventBridge cares that you are on camera.
#
# So there are two hard rules.
#
#   1. DISARM ON WEBINAR DAY. Put `./scripts/gpu-backstop.sh disarm` in the pre-flight
#      checklist, above everything else, and `arm` in the post-webinar teardown.
#   2. Pick an hour you would never rehearse through. The default is 21:00 UTC, which is
#      late enough to cover a normal working day and early enough that a forgotten
#      overnight GPU costs one night rather than a weekend.
#
# It scales the nodegroup rather than deleting anything. The weights live on the PVC and
# in S3, so a forced scale-down costs you an 8 minute `gpu.sh up`, not a re-pull.
#
# Uses an EventBridge Scheduler universal target calling eks:UpdateNodegroupConfig
# directly, so there is no Lambda to maintain and the IAM is one narrow permission on
# one nodegroup.
set -euo pipefail

export AWS_PROFILE="${SOVEREIGN_AWS_PROFILE:?set SOVEREIGN_AWS_PROFILE to the sandbox SSO profile}"
REGION=eu-west-2
# Derived, never hardcoded: this file is served publicly from the site, so the account
# id does not belong in it. sts get-caller-identity also guarantees it matches whichever
# profile is actually in effect, which a hardcoded value cannot.
ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
[ -n "$ACCOUNT" ] && [ "$ACCOUNT" != "None" ] || { echo "error: no AWS identity; check SOVEREIGN_AWS_PROFILE" >&2; exit 1; }
CLUSTER=uk-sovereign-ai
NG=gpu-od
SCHED_NAME=uk-sovereign-ai-gpu-scale-to-zero
ROLE_NAME=uk-sovereign-ai-gpu-backstop-role
HOUR_UTC="${HOUR_UTC:-21}"

die() { echo "error: $*" >&2; exit 1; }

ensure_role() {
  local arn
  arn="$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text 2>/dev/null || true)"
  if [[ -n "$arn" && "$arn" != "None" ]]; then echo "$arn"; return; fi

  aws iam create-role --role-name "$ROLE_NAME" \
    --description "Lets EventBridge Scheduler scale the sovereign AI GPU nodegroup to zero" \
    --assume-role-policy-document "{
      \"Version\": \"2012-10-17\",
      \"Statement\": [{
        \"Effect\": \"Allow\",
        \"Principal\": {\"Service\": \"scheduler.amazonaws.com\"},
        \"Action\": \"sts:AssumeRole\",
        \"Condition\": {\"StringEquals\": {\"aws:SourceAccount\": \"${ACCOUNT}\"}}
      }]
    }" --query 'Role.Arn' --output text >/dev/null

  # One action, one nodegroup. Nothing here can touch the control plane, the system
  # nodegroup, or any other cluster.
  aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name scale-gpu-nodegroup \
    --policy-document "{
      \"Version\": \"2012-10-17\",
      \"Statement\": [{
        \"Effect\": \"Allow\",
        \"Action\": \"eks:UpdateNodegroupConfig\",
        \"Resource\": \"arn:aws:eks:${REGION}:${ACCOUNT}:nodegroup/${CLUSTER}/${NG}/*\"
      }]
    }"

  # IAM is eventually consistent and Scheduler validates the role on create, so a
  # freshly made role is often not yet assumable.
  echo "waiting for the new IAM role to propagate..." >&2
  sleep 15
  aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text
}

case "${1:-status}" in
  arm)
    aws eks describe-nodegroup --region "$REGION" --cluster-name "$CLUSTER" \
      --nodegroup-name "$NG" --query 'nodegroup.status' --output text >/dev/null 2>&1 \
      || die "nodegroup ${NG} not found. Arm this after the cluster exists, not before."

    ROLE_ARN="$(ensure_role)"
    [[ -n "$ROLE_ARN" && "$ROLE_ARN" != "None" ]] || die "could not create or read ${ROLE_NAME}"

    # maxSize stays 1 so gpu.sh up still works the next morning without editing anything.
    INPUT="{\"ClusterName\":\"${CLUSTER}\",\"NodegroupName\":\"${NG}\",\"ScalingConfig\":{\"MinSize\":0,\"DesiredSize\":0,\"MaxSize\":1}}"

    if aws scheduler get-schedule --region "$REGION" --name "$SCHED_NAME" >/dev/null 2>&1; then
      verb=update-schedule
    else
      verb=create-schedule
    fi

    aws scheduler $verb --region "$REGION" --name "$SCHED_NAME" \
      --schedule-expression "cron(0 ${HOUR_UTC} * * ? *)" \
      --schedule-expression-timezone UTC \
      --flexible-time-window '{"Mode":"OFF"}' \
      --state ENABLED \
      --description "Force ${NG} to desired=0 nightly. DISARM ON WEBINAR DAY." \
      --target "{
        \"Arn\": \"arn:aws:scheduler:::aws-sdk:eks:updateNodegroupConfig\",
        \"RoleArn\": \"${ROLE_ARN}\",
        \"Input\": $(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$INPUT")
      }" >/dev/null

    echo "ARMED. ${NG} will be forced to desired=0 at ${HOUR_UTC}:00 UTC every day."
    echo
    echo "  Put this in the pre-flight checklist, ABOVE everything else:"
    echo "    ./scripts/gpu-backstop.sh disarm"
    echo
    echo "  It will happily fire mid-webinar otherwise."
    ;;

  disarm)
    aws scheduler get-schedule --region "$REGION" --name "$SCHED_NAME" >/dev/null 2>&1 \
      || { echo "not armed, nothing to disarm."; exit 0; }
    # Deliberately preserves the schedule so `arm` afterwards needs no arguments and
    # cannot pick a different time by accident.
    aws scheduler update-schedule --region "$REGION" --name "$SCHED_NAME" --state DISABLED \
      --schedule-expression "$(aws scheduler get-schedule --region "$REGION" --name "$SCHED_NAME" --query 'ScheduleExpression' --output text)" \
      --schedule-expression-timezone UTC \
      --flexible-time-window '{"Mode":"OFF"}' \
      --target "$(aws scheduler get-schedule --region "$REGION" --name "$SCHED_NAME" --query '{Arn:Target.Arn,RoleArn:Target.RoleArn,Input:Target.Input}' --output json)" >/dev/null
    echo "DISARMED. The GPU will not be scaled down on a schedule."
    echo "Re-arm after the webinar:  ./scripts/gpu-backstop.sh arm"
    ;;

  status)
    if aws scheduler get-schedule --region "$REGION" --name "$SCHED_NAME" >/dev/null 2>&1; then
      aws scheduler get-schedule --region "$REGION" --name "$SCHED_NAME" \
        --query '{state:State,cron:ScheduleExpression,tz:ScheduleExpressionTimezone}' --output table
    else
      echo "not armed"
    fi
    echo "=== current nodegroup scaling"
    aws eks describe-nodegroup --region "$REGION" --cluster-name "$CLUSTER" \
      --nodegroup-name "$NG" --query 'nodegroup.scalingConfig' --output json 2>/dev/null \
      || echo "  nodegroup not present (cluster torn down?)"
    ;;

  remove)
    aws scheduler delete-schedule --region "$REGION" --name "$SCHED_NAME" 2>/dev/null \
      && echo "schedule deleted" || echo "no schedule to delete"
    aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name scale-gpu-nodegroup 2>/dev/null || true
    aws iam delete-role --role-name "$ROLE_NAME" 2>/dev/null \
      && echo "role deleted" || echo "no role to delete"
    ;;

  *) echo "usage: $0 {arm|disarm|status|remove}"; exit 1 ;;
esac
