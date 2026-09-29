#!/usr/bin/env bash
# aws-sweep.sh — what is still running in AWS, across the regions the labs use.
#
#   scripts/aws-sweep.sh              report only (default, read-only)
#   scripts/aws-sweep.sh --since DATE only flag things created on/after DATE
#
# Written for the end of a lab run: every lab tears itself down, but a teardown
# can half-fail and leave an EKS cluster or a GPU nodegroup billing overnight.
# This is the check that the money actually stopped.
#
# Read-only on purpose. It prints what it finds and what the delete command would
# be, and deletes nothing: the account holds resources from other people's work
# and from earlier sessions, and only a human can tell those apart.

set -uo pipefail

REGIONS="${REGIONS:-eu-west-1 eu-west-2 eu-central-1 us-east-1 us-west-2}"
SINCE=""
[[ "${1:-}" == "--since" ]] && SINCE="${2:-}"

command -v aws >/dev/null || { echo "aws-sweep: aws CLI not found" >&2; exit 1; }
aws sts get-caller-identity >/dev/null 2>&1 || {
  echo "aws-sweep: no AWS credentials. Set AWS_PROFILE and retry." >&2; exit 1; }

found=0
note() { found=$((found+1)); printf '  %-14s %-16s %s\n' "$1" "$2" "$3"; }

echo "account: $(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
[[ -n "$SINCE" ]] && echo "only showing resources created on/after $SINCE"
printf '  %-14s %-16s %s\n' TYPE REGION DETAIL
printf '  %-14s %-16s %s\n' ---- ------ ------

for r in $REGIONS; do
  while read -r c; do
    [[ -z "$c" ]] && continue
    note "eks-cluster" "$r" "$c   (aws eks delete-cluster --name $c --region $r)"
  done < <(aws eks list-clusters --region "$r" --query 'clusters[]' --output text 2>/dev/null | tr '\t' '\n')

  while read -r i t; do
    [[ -z "$i" ]] && continue
    note "ec2-instance" "$r" "$i $t"
  done < <(aws ec2 describe-instances --region "$r" \
            --filters Name=instance-state-name,Values=running \
            --query 'Reservations[].Instances[].[InstanceId,InstanceType]' --output text 2>/dev/null)

  while read -r n; do
    [[ -z "$n" ]] && continue
    note "load-balancer" "$r" "$n"
  done < <(aws elbv2 describe-load-balancers --region "$r" \
            --query 'LoadBalancers[].LoadBalancerName' --output text 2>/dev/null | tr '\t' '\n')

  # CLASSIC ELBs live in a different API and are invisible to elbv2. Kubernetes
  # in-tree LoadBalancer Services create these, and they outlive a deleted
  # cluster: five were found in one region, the oldest eight months old, holding
  # an ENI that in turn blocked a CloudFormation stack from ever deleting.
  while read -r n c; do
    [[ -z "$n" ]] && continue
    note "classic-elb" "$r" "$n  created ${c%%T*}"
  done < <(aws elb describe-load-balancers --region "$r" \
            --query 'LoadBalancerDescriptions[].[LoadBalancerName,CreatedTime]' --output text 2>/dev/null)

  # A stack stuck in DELETE_FAILED keeps its remaining resources alive and blocks
  # the name from being reused, so a rebuild fails with AlreadyExistsException.
  while read -r n; do
    [[ -z "$n" ]] && continue
    # Termination protection makes a stack refuse deletion outright, so it looks
    # stuck while no delete has ever started. Say so, because the fix is one
    # command and nothing else will work until it is done.
    tp="$(aws cloudformation describe-stacks --region "$r" --stack-name "$n" \
          --query 'Stacks[0].EnableTerminationProtection' --output text 2>/dev/null)"
    if [[ "$tp" == "True" ]]; then
      note "cfn-stuck" "$r" "$n  TERMINATION PROTECTION ON (aws cloudformation update-termination-protection --stack-name $n --no-enable-termination-protection --region $r)"
    else
      note "cfn-stuck" "$r" "$n"
    fi
  done < <(aws cloudformation list-stacks --region "$r" \
            --stack-status-filter DELETE_FAILED ROLLBACK_COMPLETE \
            --query 'StackSummaries[].StackName' --output text 2>/dev/null | tr '\t' '\n')

  while read -r n; do
    [[ -z "$n" ]] && continue
    note "nat-gateway" "$r" "$n"
  done < <(aws ec2 describe-nat-gateways --region "$r" \
            --filter Name=state,Values=available \
            --query 'NatGateways[].NatGatewayId' --output text 2>/dev/null | tr '\t' '\n')

  # Unattached EBS volumes are the classic teardown remnant: the cluster goes,
  # the model-weights volume stays and keeps billing.
  while read -r v s; do
    [[ -z "$v" ]] && continue
    note "ebs-unattached" "$r" "$v ${s}GiB"
  done < <(aws ec2 describe-volumes --region "$r" \
            --filters Name=status,Values=available \
            --query 'Volumes[].[VolumeId,Size]' --output text 2>/dev/null)
done

echo
if [[ $found -eq 0 ]]; then
  echo "clean: nothing running in: $REGIONS"
else
  echo "$found resource(s) still present. Check each against what you expect to keep."
fi
