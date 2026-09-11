#!/usr/bin/env bash
# Harness entry point: up | test | teardown.
#
# Standalone. `up` builds an EKS cluster, installs agentgateway with the inference
# extension, serves one model on two GPU cards, wires the InferencePool and its Endpoint
# Picker, and leaves a working environment. `test` runs the same load through four
# schedulers. `teardown` deletes the cluster.
#
# The GPUs are the cost: two g7e.2xlarge at about $11.70/hr together. Nothing else here
# is expensive, and `gpu.sh down` stops the meter without losing the weights.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

case "${1:-}" in
  up)
    require eksctl; require aws; require kubectl; require helm
    require_secrets

    step "1/4  cluster"
    if aws eks describe-cluster --region "$AWS_REGION" --name "$EKS_CLUSTER" >/dev/null 2>&1; then
      log "cluster $EKS_CLUSTER already exists, skipping"
      # An existing cluster may have been left with the GPU meter off. Bring the pair
      # back before anything tries to schedule a model onto nothing.
      "$LAB_ROOT/scripts/gpu.sh" up
    else
      eksctl create cluster -f "$LAB_ROOT/eks/cluster.yaml"
    fi

    step "2/4  agentgateway ($AGW_EDITION) and the inference extension"
    "$LAB_ROOT/scripts/01-gateway.sh"

    step "3/4  the model on both cards (slow: ~31 GB per replica on a cold cluster)"
    "$LAB_ROOT/scripts/02-models.sh"

    step "4/4  InferencePool, Endpoint Picker and the route"
    "$LAB_ROOT/scripts/03-pool.sh" default

    step "done. Prove it with:  ./scripts/test.sh"
    ;;

  test)
    exec "$LAB_ROOT/scripts/test.sh" "${2:-prefix}"
    ;;

  teardown)
    resolve_ctx
    step "removing Gateways first"
    # Gateways own load balancers, and a load balancer still attached to a subnet stops
    # the VPC deleting, which surfaces much later as a DELETE_FAILED stack and an
    # AlreadyExistsException on the next build. The Gateway here is pinned to ClusterIP
    # so there should be nothing to wait for, but "should be" is how the last one got
    # left behind.
    kc delete gateway --all -A --timeout=120s 2>/dev/null || true

    log "waiting for load balancers in this VPC to go"
    vpc="$(aws eks describe-cluster --region "$AWS_REGION" --name "$EKS_CLUSTER" \
            --query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null || true)"
    if [ -n "$vpc" ] && [ "$vpc" != "None" ]; then
      for _ in $(seq 1 30); do
        # Classic ELBs are a different API from elbv2 and each misses the other's
        # load balancers entirely, so both are checked.
        n1=$(aws elb describe-load-balancers --region "$AWS_REGION" \
              --query "length(LoadBalancerDescriptions[?VPCId=='$vpc'])" --output text 2>/dev/null || echo 0)
        n2=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
              --query "length(LoadBalancers[?VpcId=='$vpc'])" --output text 2>/dev/null || echo 0)
        [ "$n1" = "0" ] && [ "$n2" = "0" ] && break
        sleep 10
      done
    fi

    step "deleting the cluster"
    eksctl delete cluster --region "$AWS_REGION" --name "$EKS_CLUSTER" \
      --disable-nodegroup-eviction --wait

    # Never trust a teardown's exit code, read the state back.
    step "state after teardown"
    aws eks list-clusters --region "$AWS_REGION" --query clusters --output text
    echo
    log "The volumes holding the weights are deleted with the cluster (reclaimPolicy:"
    log "Delete on gp3-fast), so a rebuild downloads them again. Check for leftovers the"
    log "cluster delete cannot see:"
    log "  ../scripts/aws-sweep.sh"
    ;;

  *)
    echo "usage: $0 {up|test|teardown}" >&2
    exit 1
    ;;
esac
