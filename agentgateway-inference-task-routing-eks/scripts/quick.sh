#!/usr/bin/env bash
# Harness entry point: up | test | teardown.
#
# `up` installs the platform when it is not there (cluster, agentgateway, device plugin,
# models; every step skips what exists, so a cluster Part 3 built is reused), then applies
# the five steps of the flow. `test` runs the flow and the controls. `teardown` puts Part 3's
# routing back and, if this lab built the cluster, deletes it; otherwise it stops the GPU
# meter. Needs ANTHROPIC_API_KEY, and an AWS identity.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EKS_CLUSTER="${EKS_CLUSTER:-model-routing}"; AWS_REGION="${AWS_REGION:-eu-west-2}"
export EKS_CLUSTER AWS_REGION
case "${1:-}" in
  up)
    "$HERE/scripts/platform/up.sh"
    "$HERE/scripts/00-check.sh"
    "$HERE/scripts/01-identity.sh"
    "$HERE/scripts/02-router.sh"
    "$HERE/scripts/03-opa.sh"
    "$HERE/scripts/04-decision-gateway.sh"
    "$HERE/scripts/05-classify-gateway.sh"
    ;;
  test)
    "$HERE/scripts/06-test-flow.sh"
    "$HERE/scripts/07-test-controls.sh"
    ;;
  teardown)
    . "$HERE/scripts/lib.sh"
    "$HERE/scripts/99-restore.sh" || true
    if [ "$(kubectl -n kube-system get configmap lab-owner -o jsonpath='{.data.lab}' 2>/dev/null)" = "agentgateway-inference-task-routing-eks" ]; then
      echo "############ this lab built the cluster: deleting it"
      kubectl delete gateway --all -A --timeout=120s 2>/dev/null || true
      eksctl delete cluster --region "$AWS_REGION" --name "$EKS_CLUSTER" --disable-nodegroup-eviction --wait
      aws eks list-clusters --region "$AWS_REGION" --query clusters --output text
    else
      echo "############ another lab's cluster: stopping the GPU meter"
      "$HERE/scripts/platform/gpu.sh" down
    fi
    ;;
  *) echo "usage: $0 {up|test|teardown}" >&2; exit 1 ;;
esac
