#!/usr/bin/env bash
# Part 1's two models on one card.
#
#   ./scripts/02-models.sh
#
# Applies Part 1's own model manifests with four numbers changed per Deployment, so the
# two vLLM servers fit one 96 GB RTX PRO 6000 together rather than one each:
#
#   --gpu-memory-utilization   Mistral 0.90 -> 0.56   (48 GB bf16 weights + KV cache)
#                              Qwen    0.90 -> 0.38   (31 GB FP8 weights + KV cache)
#   --max-model-len            both -> 8192, to keep the KV cache inside those shares
#   memory requests            24Gi -> 16Gi each, cpu requests 4 -> 3 each, so both pods
#                              fit the node's 60 GiB and 7.6 CPU of allocatable
#
# Time-slicing shares the card's compute; these shares divide its memory. vLLM refuses to
# start if its share is not free, so the two add up to 0.94 and not 1.0. First run pulls
# 45 GB for Mistral and 31 GB for Qwen onto gp3 volumes, so allow 40 minutes; a later run
# against the same volumes reloads in a few minutes.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/scripts/lib.sh"
render() { # render <part1 manifest> <utilisation>
  python3 - "$1" "$2" <<'PY'
import re, sys
text, util = open(sys.argv[1]).read(), sys.argv[2]
text = re.sub(r"--gpu-memory-utilization=0\.90", f"--gpu-memory-utilization={util}", text)
text = re.sub(r"--max-model-len=\d+", "--max-model-len=8192", text)
# resources of the vllm container only: requests memory 24Gi -> 16Gi, cpu "4" -> "3"
text = re.sub(r'(requests:\n\s+nvidia\.com/gpu: "1"\n\s+memory: )24Gi(\n\s+cpu: )"4"', r'\g<1>16Gi\g<2>"3"', text)
sys.stdout.write(text)
PY
}
banner "both models on the one card"
render "$PART1_DIR/yaml/00-mistral-model.yaml" 0.56 | kubectl apply -f -
render "$PART1_DIR/yaml/01-qwen-model.yaml"    0.38 | kubectl apply -f -
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
echo
echo "Next: ./scripts/03-identity.sh"
