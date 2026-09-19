#!/usr/bin/env bash
# Part 1's two models, a GPU node each.
#
#   ./scripts/02-models.sh
#
# Applies Part 1's own model manifests with one number changed per Deployment, the context
# window:
#
#   --max-model-len   Mistral 16384 -> 131072
#                     Qwen    32768 -> 262144
#
# Part 1 sizes the window for a first boot. An agent client needs more of it, because it
# sends its instructions and its tools on every turn before the person has typed anything,
# and vLLM refuses a request longer than the window rather than shortening it.
#
# --gpu-memory-utilization stays at Part 1's 0.90, which is what a card to itself allows.
# vLLM prints "GPU KV cache size" at startup and refuses to start when one full-length
# request would need more cache than that. First run pulls 45 GB for Mistral and 31 GB for
# Qwen onto gp3 volumes, so allow 40 minutes; a later run against the same volumes reloads
# in a few minutes.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/scripts/lib.sh"
render() { # render <part1 manifest> <window>
  python3 - "$1" "$2" <<'PYEOF'
import re, sys
text, window = open(sys.argv[1]).read(), sys.argv[2]
text = re.sub(r"--max-model-len=\d+", f"--max-model-len={window}", text)
sys.stdout.write(text)
PYEOF
}
banner "both models, a GPU node each"
render "$PART1_DIR/yaml/00-mistral-model.yaml" 131072 | kubectl apply -f -
render "$PART1_DIR/yaml/01-qwen-model.yaml"    262144 | kubectl apply -f -
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
