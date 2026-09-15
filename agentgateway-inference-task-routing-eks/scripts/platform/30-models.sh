#!/usr/bin/env bash
# Platform step 4: the two open-weight models on vLLM, both on the one card.
#
#   ./scripts/platform/30-models.sh
#
# Applies yaml/platform/30-vllm-mistral.yaml and 31-vllm-qwen.yaml: a namespace, a PVC and a
# Service and a Deployment per model, with an init container that pulls the weights onto the
# PVC on first run. 45 GB for Mistral and 31 GB for Qwen, so allow 40 minutes the first time;
# a later run against the same volumes reloads in a few minutes.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$HERE/scripts/lib.sh"
banner "both models on the one card"
kubectl apply -f "$HERE/yaml/platform/30-vllm-mistral.yaml"
kubectl apply -f "$HERE/yaml/platform/31-vllm-qwen.yaml"
# Wait on Available, not rollout status: a pod that waited for a GPU or a volume leaves
# ProgressDeadlineExceeded on its Deployment, and rollout status then gives up at once.
banner "waiting for Mistral (first run pulls 45 GB)"
kubectl wait --for=condition=Available deploy/vllm      -n models --timeout=2400s
banner "waiting for Qwen (first run pulls 31 GB)"
kubectl wait --for=condition=Available deploy/vllm-qwen -n models --timeout=2400s
banner "both on one node?"
kubectl -n models get pods -l 'app in (vllm,vllm-qwen)' -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,READY:.status.containerStatuses[0].ready'
banner "what each server advertises"
for d in vllm vllm-qwen; do
  printf '  %-10s ' "$d"
  kubectl exec -n models "deploy/$d" -c vllm -- python3 -c \
    "import json,urllib.request;print([m['id'] for m in json.load(urllib.request.urlopen('http://localhost:8000/v1/models'))['data']])" 2>/dev/null || echo "not ready"
done
banner "the card"
kubectl -n models exec deploy/vllm-qwen -c vllm -- nvidia-smi --query-gpu=name,memory.total,memory.used --format=csv 2>/dev/null || true
echo
echo "Platform ready. Next: ./scripts/00-check.sh, then the flow steps from ./scripts/01-identity.sh"
