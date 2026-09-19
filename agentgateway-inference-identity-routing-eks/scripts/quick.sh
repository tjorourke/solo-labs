#!/usr/bin/env bash
# Harness entry point: up | test | teardown.
#
# `up` reuses the Part 1 cluster when it exists and otherwise builds it with one GPU node,
# then installs agentgateway v1.5.0 and the NVIDIA device plugin, puts each open-weight
# model on its own GPU node, mints the identities, deploys OPA and the router, the four
# backends, the policy and the route. Needs OPENAI_API_KEY and ANTHROPIC_API_KEY.
#
# `teardown` deletes the cluster only if this lab created it (the lab-owner marker in
# kube-system says so). On a cluster Part 1 built it restores Part 1's routing and scales
# the GPU nodegroup to zero, which stops the only meter that matters.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EKS_CLUSTER="${EKS_CLUSTER:-model-routing}"; AWS_REGION="${AWS_REGION:-eu-west-2}"
export EKS_CLUSTER AWS_REGION
banner() { echo; echo "############ $*"; }
case "${1:-}" in
  up)
    banner "1/8  check";            "$HERE/scripts/00-check.sh"
    banner "2/8  cluster, agentgateway, device plugin"; "$HERE/scripts/01-cluster.sh"
    banner "3/8  both models on one GPU (slow on a fresh cluster: 76 GB of weights)"; "$HERE/scripts/02-models.sh"
    banner "4/8  identities";       "$HERE/scripts/03-identity.sh"
    banner "5/8  gateway and OPA";  "$HERE/scripts/04-opa.sh"
    banner "6/8  semantic router";  "$HERE/scripts/05-semantic-router.sh"
    banner "7/8  backends";         "$HERE/scripts/06-backends.sh"
    banner "8/8  policy and route"; "$HERE/scripts/07-routing.sh"
    ;;
  test)
    "$HERE/scripts/09-test-matrix.sh"
    "$HERE/scripts/10-test-negative.sh"
    ;;
  teardown)
    . "$HERE/scripts/lib.sh"
    if [ "$(kubectl -n kube-system get configmap lab-owner -o jsonpath='{.data.lab}' 2>/dev/null)" = "agentgateway-inference-identity-routing-eks" ]; then
      banner "this lab built the cluster: deleting it"
      # Gateways own load balancers, and a load balancer still attached to a subnet stops
      # the VPC deleting. Remove them first and wait for them to go.
      kubectl delete gateway --all -A --timeout=120s 2>/dev/null || true
      vpc="$(aws eks describe-cluster --region "$AWS_REGION" --name "$EKS_CLUSTER" --query 'cluster.resourcesVpcConfig.vpcId' --output text)"
      for _ in $(seq 1 30); do
        n=$(aws elb describe-load-balancers --region "$AWS_REGION" --query "length(LoadBalancerDescriptions[?VPCId=='$vpc'])" --output text 2>/dev/null || echo 0)
        [ "$n" = "0" ] && break; sleep 10
      done
      eksctl delete cluster --region "$AWS_REGION" --name "$EKS_CLUSTER" --disable-nodegroup-eviction --wait
      banner "state after teardown (never trust the exit code)"
      aws eks list-clusters --region "$AWS_REGION" --query clusters --output text
      echo "Check for leftovers the cluster delete cannot see:  ../scripts/aws-sweep.sh"
    else
      banner "Part 1's cluster: restoring its routing and stopping the GPU meter"
      "$HERE/scripts/99-restore.sh"
      "$HERE/scripts/gpu.sh" down
    fi
    ;;
  *) echo "usage: $0 {up|test|teardown}" >&2; exit 1 ;;
esac
