#!/usr/bin/env bash
# 03-model-servers.sh — deploy the self-hosted model pool: two llm-d inference
# simulator replicas that stand in for vLLM. Both carry app=vllm-sim so the
# InferencePool selects them. Each pins its KV-cache / queue gauges from a
# mounted config so the endpoint picker's decision is deterministic:
#   pool-a starts COLD (kv-cache 0.10), pool-b starts HOT (kv-cache 0.90).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

step "Creating namespace '$NS'"
kc create namespace "$NS" --dry-run=client -o yaml | kc apply -f - >/dev/null
ok "namespace '$NS' ready"

step "Deploying the model pool (llm-d inference simulator ×2)"
kc apply -f "$LAB_ROOT/$YAML_DIR/model-servers/deployment.yaml" >/dev/null
kc -n "$NS" rollout status deploy/vllm-pool-a --timeout=180s >/dev/null
kc -n "$NS" rollout status deploy/vllm-pool-b --timeout=180s >/dev/null
ok "pool-a (COLD) and pool-b (HOT) are Ready"
kc -n "$NS" get pods -l app=vllm-sim -o wide >&2 || true
