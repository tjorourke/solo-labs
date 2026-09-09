#!/usr/bin/env bash
# Harness entry point: up | test | teardown.
#
# This lab LAYERS on sovereign-ai-uk-eks. It does not build a cluster, a gateway or
# a mesh, and it does not tear any of those down. It adds a second model, two
# backends, one policy and one route, and removes exactly those again.
#
# The one thing here that costs real money is the second GPU node, so `up` scales it
# and `teardown` scales it back. Everything else is a handful of objects.
set -euo pipefail

: "${SOVEREIGN_AWS_PROFILE:?set SOVEREIGN_AWS_PROFILE to the sandbox SSO profile}"
export AWS_PROFILE="$SOVEREIGN_AWS_PROFILE"
REGION=eu-west-2
CLUSTER=uk-sovereign-ai
NG=gpu-od
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
[ -n "$ACCOUNT" ] && [ "$ACCOUNT" != "None" ] || { echo "error: no AWS identity; check SOVEREIGN_AWS_PROFILE" >&2; exit 1; }
CTX="arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${CLUSTER}"
kubectl() { command kubectl --context "$CTX" "$@"; }

banner() { echo; echo "==> $*"; }

scale_gpu() {
  # maxSize has to move with desiredSize. The parent lab's gpu.sh hardcodes
  # maxSize=1, so a plain desiredSize=2 there is silently capped at one node and the
  # second model sits Pending on Insufficient nvidia.com/gpu with nothing to explain
  # why.
  aws eks update-nodegroup-config --region "$REGION" --cluster-name "$CLUSTER" \
    --nodegroup-name "$NG" --scaling-config "minSize=0,maxSize=$1,desiredSize=$1" >/dev/null
  echo "$NG -> desired=$1"
}

wait_gpu_nodes() {
  local want="$1"
  banner "waiting for $want GPU node(s) to advertise nvidia.com/gpu (up to 30m)"
  for _ in $(seq 1 120); do
    local n
    n=$(kubectl get nodes -l role=gpu \
          -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null \
        | grep -c '^1$' || true)
    [ "${n:-0}" -ge "$want" ] && { echo "$n GPU node(s) ready"; return 0; }
    sleep 15
  done
  echo "ERROR: fewer than $want GPU nodes advertised a GPU within 30m." >&2
  echo "  check nodegroup HEALTH, not just the node list:" >&2
  echo "  aws eks describe-nodegroup --region $REGION --cluster-name $CLUSTER --nodegroup-name $NG --query 'nodegroup.health'" >&2
  return 1
}

case "${1:-}" in
  up)
    banner "second GPU node"
    scale_gpu 2
    wait_gpu_nodes 2

    banner "both models (Qwen's first run pulls ~31 GB of weights)"
    kubectl apply -f "$HERE/yaml/00-mistral-model.yaml"
    kubectl apply -f "$HERE/yaml/01-qwen-model.yaml"
    kubectl rollout status deploy/vllm -n models --timeout=1500s
    # 25 minutes: the weight pull, then a 9 GB image pull on a cold node, then the
    # load and CUDA graph capture. Observed end to end at about 12 minutes.
    kubectl rollout status deploy/vllm-qwen -n models --timeout=1500s

    banner "gateway, backends, routing policy and route"
    kubectl apply -f "$HERE/yaml/05-gateway.yaml"
    kubectl apply -f "$HERE/yaml/10-backends.yaml"
    kubectl apply -f "$HERE/yaml/20-routing-policy.yaml"
    kubectl apply -f "$HERE/yaml/30-httproute.yaml"
    kubectl apply -f "$HERE/yaml/40-kagent-modelconfig.yaml"

    # Accepted+Attached is not cosmetic. A policy that fails to attach leaves the
    # header unset, no rule matches, and every request quietly serves the default
    # model with a 200.
    banner "attachment status"
    kubectl get enterpriseagentgatewaybackends,enterpriseagentgatewaypolicies -n agentgateway-system \
      | grep -E 'NAME|vllm-qwen|extract-model' || true
    ;;

  test)
    exec "$HERE/scripts/test.sh"
    ;;

  teardown)
    banner "removing this lab's objects (the parent lab is left alone)"
    kubectl delete -f "$HERE/yaml/40-kagent-modelconfig.yaml" --ignore-not-found
    kubectl delete -f "$HERE/yaml/30-httproute.yaml" --ignore-not-found
    kubectl delete -f "$HERE/yaml/20-routing-policy.yaml" --ignore-not-found
    kubectl delete -f "$HERE/yaml/10-backends.yaml" --ignore-not-found
    kubectl delete -f "$HERE/yaml/01-qwen-model.yaml" --ignore-not-found
    kubectl delete -f "$HERE/yaml/05-gateway.yaml" --ignore-not-found

    banner "back to one GPU node"
    # Back to 1, not 0: the parent lab's Mistral is still running on the other card
    # and scaling to 0 here would take part 1 down with it.
    scale_gpu 1

    # Never trust a teardown's exit code, read the state back.
    banner "state after teardown"
    kubectl get pods -n models 2>/dev/null || true
    aws eks describe-nodegroup --region "$REGION" --cluster-name "$CLUSTER" \
      --nodegroup-name "$NG" --query 'nodegroup.scalingConfig' --output json
    echo
    echo "The PVC qwen-weights is deliberately NOT deleted: it holds 31 GB that costs"
    echo "another download to replace. Remove it by hand when you are done for good:"
    echo "  kubectl --context \$CTX -n models delete pvc qwen-weights"
    ;;

  *)
    echo "usage: $0 {up|test|teardown}" >&2
    exit 1
    ;;
esac
