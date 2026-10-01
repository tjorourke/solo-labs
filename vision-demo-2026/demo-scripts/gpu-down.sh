#!/usr/bin/env bash
# Redirect all GPU-hosted model traffic to frontier models when GPUs are scaled down.
# Run ./gpu-up.sh to revert.
set -euo pipefail
CTX="${CTX:-arn:aws:eks:eu-west-2:253915036081:cluster/model-routing}"
NS=agentgateway-system
SAVE_DIR="$(cd "$(dirname "$0")" && pwd)/.gpu-snapshots"
mkdir -p "$SAVE_DIR"

echo "→ saving current routes to $SAVE_DIR"
for route in decision-routing kernwerk-decision kernwerk-private; do
  kubectl --context "$CTX" -n "$NS" get httproute "$route" -o yaml > "$SAVE_DIR/$route.yaml"
done

echo "→ decision-routing: vllm-qwen → anthropic, vllm-mistral → anthropic"
kubectl --context "$CTX" -n "$NS" get httproute decision-routing -o json \
  | sed 's/"name": "vllm-qwen"/"name": "anthropic"/g; s/"name": "vllm-mistral"/"name": "anthropic"/g' \
  | kubectl --context "$CTX" apply -f -

echo "→ kernwerk-decision: vllm-qwen → kernwerk-claude, vllm-mistral → kernwerk-claude"
kubectl --context "$CTX" -n "$NS" get httproute kernwerk-decision -o json \
  | sed 's/"name": "vllm-qwen"/"name": "kernwerk-claude"/g; s/"name": "vllm-mistral"/"name": "kernwerk-claude"/g' \
  | kubectl --context "$CTX" apply -f -

echo "→ kernwerk-private: kernwerk-private backend → kernwerk-claude"
kubectl --context "$CTX" -n "$NS" get httproute kernwerk-private -o json \
  | sed 's/"name": "kernwerk-private", "group": "enterpriseagentgateway.solo.io"/"name": "kernwerk-claude", "group": "enterpriseagentgateway.solo.io"/g' \
  | kubectl --context "$CTX" apply -f -

echo "✓ GPU traffic redirected to Claude. Run ./gpu-up.sh to revert."
