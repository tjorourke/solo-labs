#!/usr/bin/env bash
# Scale the spot GPU node up and down. This is the only thing in the build that
# costs real money, so it lives behind one obvious command.
#
#   ./scripts/gpu.sh up      bring up 1 on-demand g6.12xlarge ($5.84/hr)
#   ./scripts/gpu.sh down    scale to 0. Run this when you stop for the day.
#   ./scripts/gpu.sh status  what is running and what it is costing
#
# Not spot. Spot returns UnfulfillableCapacity for 4-GPU nodes in London and
# placement scores are 1/10 in every AZ, whatever the flat price history says.
#
# "down" is the daily switch, not the only one. It leaves an idle floor of
# roughly $330/mo: 2x m6i.large ($162), EKS control plane ($73), the 120Gi
# provisioned-IOPS PVC ($58) and the NAT gateway ($37). After the webinar the
# real switch is `eksctl delete cluster`, which takes that to about a dollar.
# That teardown is only safe because the weights are also in S3 and
# yaml/39-model-restore-job.yaml puts them back.
set -euo pipefail

# Hardcoded, NOT ${AWS_PROFILE:-...}. This shell profile exports
# AWS_PROFILE=weaveone, so a :- default silently inherits the wrong account and
# you get "No cluster found for name: uk-sovereign-ai" from a cluster that is
# plainly right there. Override deliberately with SOVEREIGN_AWS_PROFILE.
export AWS_PROFILE="${SOVEREIGN_AWS_PROFILE:?set SOVEREIGN_AWS_PROFILE to the sandbox SSO profile}"
REGION=eu-west-2
CLUSTER=uk-sovereign-ai
NG=gpu-od

# Always address the cluster explicitly. This laptop has a dozen kube contexts
# and any kind cluster that gets created steals current-context, so a bare
# kubectl here can quietly point at the wrong cluster.
# Derived, never hardcoded: this file is served publicly from the site, so the account
# id does not belong in it. sts get-caller-identity also guarantees it matches whichever
# profile is actually in effect, which a hardcoded value cannot.
ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
[ -n "$ACCOUNT" ] && [ "$ACCOUNT" != "None" ] || { echo "error: no AWS identity; check SOVEREIGN_AWS_PROFILE" >&2; exit 1; }
CTX="arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${CLUSTER}"
kubectl() { command kubectl --context "$CTX" "$@"; }

scale() {
  aws eks update-nodegroup-config --region "$REGION" --cluster-name "$CLUSTER" \
    --nodegroup-name "$NG" --scaling-config "minSize=$1,maxSize=1,desiredSize=$1" >/dev/null
  echo "$NG -> desired=$1"
}

case "${1:-status}" in
  up)
    scale 1
    echo "waiting for the node to register and advertise its GPUs..."
    for i in $(seq 1 60); do
      n=$(kubectl get nodes -l role=gpu -o name 2>/dev/null | wc -l | tr -d ' ')
      if [ "$n" != "0" ]; then
        g=$(kubectl get nodes -l role=gpu \
              -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null || true)
        [ -n "$g" ] && { echo "GPU node ready, nvidia.com/gpu: $g"; break; }
      fi
      sleep 15
    done
    kubectl get nodes -l role=gpu \
      -o custom-columns='NAME:.metadata.name,TYPE:.metadata.labels.node\.kubernetes\.io/instance-type,ZONE:.metadata.labels.topology\.kubernetes\.io/zone,GPU:.status.allocatable.nvidia\.com/gpu'
    ;;
  down)
    scale 0
    echo "GPU meter stopped. Idle floor continues at ~\$330/mo (nodes, control plane, PVC, NAT)."
    echo "After the webinar: eksctl delete cluster --region eu-west-2 --name uk-sovereign-ai"
    ;;
  status)
    aws eks describe-nodegroup --region "$REGION" --cluster-name "$CLUSTER" \
      --nodegroup-name "$NG" \
      --query 'nodegroup.{desired:scalingConfig.desiredSize,capacity:capacityType,types:instanceTypes,status:status}' \
      --output table
    kubectl get nodes -l role=gpu 2>/dev/null || echo "no GPU nodes up"
    ;;
  *) echo "usage: $0 {up|down|status}"; exit 1 ;;
esac
