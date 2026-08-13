#!/usr/bin/env bash
# Tear the cluster down between build sessions, and actually stop paying for it.
#
#   ./scripts/teardown.sh check     what exists and what it costs (read-only)
#   ./scripts/teardown.sh down      delete the cluster AND the orphaned weights volume
#   ./scripts/teardown.sh leftovers what survived, after the fact
#
# Idle cost with the GPU already at zero is about $330/month: 2x m6i.large system
# nodes $162, control plane $73, the weights PVC $58, NAT gateway $37. Teardown takes
# that to roughly a dollar, which is the S3 copy of the weights.
#
# THE BIT THAT CATCHES PEOPLE. yaml/00-storage.yaml sets reclaimPolicy: Retain on the
# gp3-fast StorageClass, which is correct while the cluster is alive because it means a
# spot reclaim or an accidental PVC delete does not destroy 48 GB of weights. But it
# also means `eksctl delete cluster` leaves the EBS volume behind as an orphan. A
# 120 GB gp3 at 6000 IOPS and 750 MiB/s is about $58/month, and $46 of that is the
# provisioned IOPS and throughput. So "I deleted the cluster" is not "I stopped
# paying"; the volume sits in the account indefinitely and nothing references it.
#
# This script deletes it on purpose, and refuses to do so until it has confirmed the
# weights are in S3. That confirmation is the whole safety argument for deleting it:
# the S3 copy in eu-west-2 is the master, the PVC is a cache, and
# yaml/39-model-restore-job.yaml rebuilds the cache. If S3 does not have the weights,
# this stops and tells you rather than destroying the only copy.
set -euo pipefail

export AWS_PROFILE="${SOVEREIGN_AWS_PROFILE:?set SOVEREIGN_AWS_PROFILE to the sandbox SSO profile}"
REGION=eu-west-2
CLUSTER=uk-sovereign-ai
# Derived, never hardcoded: this file is served publicly from the site, so the account
# id does not belong in it. sts get-caller-identity also guarantees it matches whichever
# profile is actually in effect, which a hardcoded value cannot.
ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
[ -n "$ACCOUNT" ] && [ "$ACCOUNT" != "None" ] || { echo "error: no AWS identity; check SOVEREIGN_AWS_PROFILE" >&2; exit 1; }
BUCKET="solo-sovereign-ai-models-euw2-${ACCOUNT}"
PREFIX="mistral-small-3.2-24b"
CTX="arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${CLUSTER}"
kc() { command kubectl --context "$CTX" "$@"; }

# The weights are 8 objects totalling 48,042,223,575 bytes. Anything much smaller means
# an interrupted sync, not a finished one.
MIN_BYTES=48000000000

die() { echo "error: $*" >&2; exit 1; }

s3_bytes() {
  aws s3 ls "s3://${BUCKET}/${PREFIX}/" --recursive --summarize 2>/dev/null \
    | awk '/Total Size:/ {print $3}'
}
s3_objects() {
  aws s3 ls "s3://${BUCKET}/${PREFIX}/" --recursive --summarize 2>/dev/null \
    | awk '/Total Objects:/ {print $3}'
}

# Volumes that belonged to the model-weights PVC. Tagged by the EBS CSI driver, so this
# still finds them after the cluster and its PV objects are gone.
#
# BOTH filters are required and the cluster one is the important one. This is a SHARED
# AWS account. Matching on the PVC name alone would also match a model-weights PVC in
# any other cluster in this region, and this function feeds a delete-volume call. The
# EBS CSI driver stamps kubernetes.io/cluster/<name>=owned, so scoping to this cluster
# means nothing outside it can ever be in range.
weights_volumes() {
  aws ec2 describe-volumes --region "$REGION" \
    --filters "Name=tag:kubernetes.io/created-for/pvc/name,Values=model-weights" \
              "Name=tag:kubernetes.io/cluster/${CLUSTER},Values=owned" \
    --query 'Volumes[].[VolumeId,Size,Iops,Throughput,State]' --output text 2>/dev/null
}

show_state() {
  echo "=== S3 master copy of the weights"
  local b o
  b="$(s3_bytes)"; o="$(s3_objects)"
  printf "  s3://%s/%s  objects=%s bytes=%s\n" "$BUCKET" "$PREFIX" "${o:-0}" "${b:-0}"
  echo
  echo "=== cluster"
  aws eks describe-cluster --region "$REGION" --name "$CLUSTER" \
    --query 'cluster.status' --output text 2>/dev/null || echo "  not present"
  echo
  echo "=== EC2 instances in the cluster"
  aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:eks:cluster-name,Values=${CLUSTER}" \
              "Name=instance-state-name,Values=running,pending" \
    --query 'Reservations[].Instances[].[InstanceType,Placement.AvailabilityZone]' \
    --output text 2>/dev/null | sed 's/^/  /' || true
  echo
  echo "=== weights EBS volumes (these SURVIVE cluster deletion, reclaimPolicy Retain)"
  weights_volumes | sed 's/^/  /' || echo "  none"
  echo
  echo "=== capacity reservations (these bill whether or not anything runs in them)"
  aws ec2 describe-capacity-reservations --region "$REGION" \
    --filters Name=state,Values=active \
    --query 'CapacityReservations[].[CapacityReservationId,InstanceType,TotalInstanceCount]' \
    --output text 2>/dev/null | sed 's/^/  /' || echo "  none"
}

case "${1:-check}" in
  check)
    show_state
    ;;

  down)
    echo "=== pre-flight: is the master copy of the weights safe in S3?"
    bytes="$(s3_bytes)"; objs="$(s3_objects)"
    [[ -n "$bytes" ]] || die "cannot read s3://${BUCKET}/${PREFIX}/, refusing to delete anything"
    echo "  objects=${objs} bytes=${bytes}"
    if (( bytes < MIN_BYTES )); then
      die "S3 holds ${bytes} bytes, expected at least ${MIN_BYTES}. The weights are NOT safely mirrored. Refusing to tear down."
    fi
    echo "  weights are in S3 in eu-west-2. Safe to destroy the PVC copy."
    echo

    # Capture the volume ids BEFORE the cluster goes, because the PVC tags are the only
    # handle on them and it is much harder to identify them afterwards.
    vols="$(weights_volumes | awk '{print $1}')"
    echo "=== weights volumes to remove after the cluster is gone:"
    echo "${vols:-  none}" | sed 's/^/  /'
    echo

    # Delete LoadBalancer Services FIRST, while the cluster is still up, so the AWS cloud
    # controller removes the ELBs they created (the gateway's NLB/ELB, any console LBs).
    # eksctl delete cluster does NOT clean up k8s-created load balancers, and their leftover
    # ENIs hold the public subnets, so the VPC cannot delete and the CloudFormation stack ends
    # in DELETE_FAILED. Removing the Services first is the graceful fix.
    echo "=== removing LoadBalancer Services so their ELBs and ENIs go before the VPC"
    lbsvcs="$(kc get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
    if [[ -n "$lbsvcs" ]]; then
      echo "$lbsvcs" | while IFS=/ read -r ns name; do
        [[ -n "$name" ]] && { echo "  deleting svc $ns/$name"; kc -n "$ns" delete svc "$name" --wait=false >/dev/null 2>&1 || true; }
      done
      echo "  waiting 60s for the cloud controller to delete the ELBs..."
      sleep 60
    else
      echo "  none found (or cluster already unreachable)"
    fi
    echo

    echo "=== deleting the cluster (this takes 15-20 minutes)"
    eksctl delete cluster --region "$REGION" --name "$CLUSTER" --disable-nodegroup-eviction
    echo

    if [[ -n "$vols" ]]; then
      echo "=== deleting the orphaned weights volumes"
      for v in $vols; do
        # available means detached. Anything else means something still holds it and
        # deleting would fail anyway, so say so rather than looping.
        st="$(aws ec2 describe-volumes --region "$REGION" --volume-ids "$v" \
              --query 'Volumes[0].State' --output text 2>/dev/null || echo unknown)"
        if [[ "$st" == "available" ]]; then
          aws ec2 delete-volume --region "$REGION" --volume-id "$v" && echo "  deleted $v"
        else
          echo "  SKIPPED $v: state is '$st', not 'available'. Delete it by hand once detached:"
          echo "    aws ec2 delete-volume --region $REGION --volume-id $v"
        fi
      done
    fi
    echo
    echo "=== what is left"
    "$0" leftovers
    ;;

  leftovers)
    echo "=== cluster"
    aws eks describe-cluster --region "$REGION" --name "$CLUSTER" \
      --query 'cluster.status' --output text 2>/dev/null || echo "  gone"
    echo "=== weights volumes"
    weights_volumes | sed 's/^/  /' || echo "  gone"
    echo "=== S3 (this is meant to survive, it is the master copy)"
    printf "  objects=%s bytes=%s\n" "$(s3_objects)" "$(s3_bytes)"
    echo "=== standalone IAM policies (survive cluster deletion, harmless, reusable)"
    aws iam list-policies --scope Local \
      --query 'Policies[?starts_with(PolicyName,`uk-sovereign-ai`)].[PolicyName,AttachmentCount]' \
      --output text 2>/dev/null | sed 's/^/  /' || true
    echo
    echo "Remaining spend should now be the S3 copy of the weights, roughly a dollar a month."
    echo "To rebuild: see the rebuild section in phase2-gateway-lane.md."
    ;;

  *) echo "usage: $0 {check|down|leftovers}"; exit 1 ;;
esac
