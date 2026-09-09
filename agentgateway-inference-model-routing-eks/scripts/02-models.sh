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
. "$HERE/scripts/lib-context.sh"
resolve_ctx
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
