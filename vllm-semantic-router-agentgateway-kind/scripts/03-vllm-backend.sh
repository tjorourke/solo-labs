#!/usr/bin/env bash
# 03-vllm-backend.sh — deploy the demo vLLM backend (the llm-d inference
# simulator) into the default namespace. It serves a base model plus six mock
# LoRA adapters over the OpenAI-compatible API on :8000.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

step "Deploying vLLM simulator (base-model + 6 mock LoRA adapters)"
kc apply -f "$LAB_ROOT/yaml/vllm/deployment.yaml" >/dev/null
ok "vllm-llama3-8b-instruct applied"

log "waiting for the simulator to become Available..."
wait_deploy default vllm-llama3-8b-instruct 300s
ok "vLLM simulator ready"

step "vLLM backend ready"
echo "  Inspect adapters: kubectl --context $CTX -n default \\" >&2
echo "    exec deploy/vllm-llama3-8b-instruct -- wget -qO- localhost:8000/v1/models" >&2
echo "  Next: ./scripts/04-semantic-router.sh" >&2
