#!/usr/bin/env bash
# Harness entry point: up | test | teardown.
#
# This lab is standalone. `up` builds an EKS cluster, installs OSS agentgateway, serves
# two models on two GPUs, wires the routing, installs kagent and the semantic router,
# and leaves a working environment. `teardown` deletes the cluster.
#
# The GPUs are the cost: two g7e.2xlarge at about $11.70/hr together. Nothing else here
# is expensive, and `gpu.sh down` stops the meter without losing the weights.
set -euo pipefail

# The lab root, so the script works from anywhere.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER="${EKS_CLUSTER:-model-routing}"
REGION="${AWS_REGION:-eu-west-2}"

banner() { echo; echo "############ $*"; }

case "${1:-}" in
  up)
    banner "1/6  cluster"
    if aws eks describe-cluster --region "$REGION" --name "$CLUSTER" >/dev/null 2>&1; then
      echo "cluster $CLUSTER already exists, skipping"
    else
      eksctl create cluster -f "$HERE/eks/cluster.yaml"
    fi
    export EKS_CLUSTER="$CLUSTER"

    banner "2/6  OSS agentgateway"
    "$HERE/scripts/01-gateway.sh"

    banner "3/6  the two models (this is the slow one, ~76 GB of weights)"
    "$HERE/scripts/02-models.sh"

    banner "4/6  routing"
    "$HERE/scripts/03-routing.sh"

    banner "5/6  kagent and the agents"
    "$HERE/scripts/04-kagent.sh"

    banner "6/6  semantic router"
    "$HERE/scripts/05-semantic-router.sh"

    banner "done. Prove it with:  ./scripts/test-classifiers.sh"
    ;;

  test)
    exec "$HERE/scripts/test-classifiers.sh"
    ;;

  teardown)
    banner "deleting the cluster"
    # Gateways own load balancers, and a load balancer still attached to a subnet stops
    # the VPC deleting, which surfaces much later as a DELETE_FAILED stack and an
    # AlreadyExistsException on the next build. Remove them first and let them go.
    export EKS_CLUSTER="$CLUSTER" AWS_REGION="$REGION"
    . "$HERE/scripts/lib-context.sh"
    resolve_ctx
    kubectl --context "$CTX" delete gateway --all -A --timeout=120s 2>/dev/null || true
    echo "waiting for load balancers to go"
    for _ in $(seq 1 30); do
      n=$(aws elb describe-load-balancers --region "$REGION" \
            --query "length(LoadBalancerDescriptions[?VPCId=='$(aws eks describe-cluster --region "$REGION" --name "$CLUSTER" --query 'cluster.resourcesVpcConfig.vpcId' --output text)'])" \
            --output text 2>/dev/null || echo 0)
      [ "$n" = "0" ] && break
      sleep 10
    done
    eksctl delete cluster --region "$REGION" --name "$CLUSTER" --disable-nodegroup-eviction --wait

    # Never trust a teardown's exit code, read the state back.
    banner "state after teardown"
    aws eks list-clusters --region "$REGION" --query clusters --output text
    echo
    echo "Check for leftovers the cluster delete cannot see (classic ELBs, orphan volumes,"
    echo "NAT gateways, DELETE_FAILED stacks):"
    echo "  ../scripts/aws-sweep.sh"
    ;;

  *)
    echo "usage: $0 {up|test|teardown}" >&2
    exit 1
    ;;
esac
