#!/usr/bin/env bash
# Deploy both models, one per GPU node.
#
#   ./scripts/02-models.sh
#
# First run pulls 45 GB for Mistral and 31 GB for Qwen, so allow half an hour. Both
# are fetched by init containers so the volume binds on the node that will serve the
# model; a standalone Job can bind it to the wrong node and leave the pod Pending.
set -euo pipefail

# The lab root, so the script works from anywhere.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Cluster selection: current context by default, KUBE_CONTEXT to name one, or
# EKS_CLUSTER for the cloud case where the context name is an ARN nobody types.
if [ -n "${KUBE_CONTEXT:-}" ]; then
  CTX="$KUBE_CONTEXT"
elif [ -n "${EKS_CLUSTER:-}" ]; then
  REGION="${AWS_REGION:-eu-west-2}"
  ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
  [ -n "$ACCOUNT" ] && [ "$ACCOUNT" != "None" ] \
    || { echo "error: no AWS identity. Check AWS_PROFILE, or run aws sso login." >&2; exit 1; }
  CTX="arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${EKS_CLUSTER}"
else
  CTX="$(kubectl config current-context 2>/dev/null)"
  [ -n "$CTX" ] || { echo "error: no current kubectl context, and neither KUBE_CONTEXT nor EKS_CLUSTER is set." >&2; exit 1; }
fi
kubectl() { command kubectl --context "$CTX" "$@"; }
helm_()   { helm --kube-context "$CTX" "$@"; }

banner() { echo; echo "==> $*"; }

banner "both models (first run pulls ~76 GB of weights in total)"
kubectl apply -f "$HERE/yaml/00-mistral-model.yaml"
kubectl apply -f "$HERE/yaml/01-qwen-model.yaml"

# 40 minutes. The weight pull dominates, then a 9 GB image pull on a cold node, then
# the load and CUDA graph capture.
banner "waiting for Mistral"
kubectl rollout status deploy/vllm      -n models --timeout=2400s
banner "waiting for Qwen"
kubectl rollout status deploy/vllm-qwen -n models --timeout=2400s

banner "what each server advertises"
for d in vllm vllm-qwen; do
  printf '  %-10s ' "$d"
  kubectl exec -n models "deploy/$d" -c vllm -- python3 -c \
    "import json,urllib.request;print([m['id'] for m in json.load(urllib.request.urlopen('http://localhost:8000/v1/models'))['data']])" 2>/dev/null || echo "not ready"
done
