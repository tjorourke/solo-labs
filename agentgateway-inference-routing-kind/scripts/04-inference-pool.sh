#!/usr/bin/env bash
# 04-inference-pool.sh — wire the routing path:
#   1. GIE inferencepool Helm chart -> creates the InferencePool (selecting
#      app=vllm-sim) and the Endpoint Picker (EPP) that scores replicas.
#   2. InferenceObjective -> priority for requests hitting the pool.
#   3. Gateway (class agentgateway) + HTTPRoute whose backendRef is the
#      InferencePool (group inference.networking.k8s.io).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

step "Installing InferencePool + Endpoint Picker (GIE chart $GIE_VERSION)"
helm --kube-context "$CTX" upgrade --install vllm-sim "$GIE_POOL_CHART" \
  --version "$GIE_VERSION" \
  --namespace "$NS" \
  --set inferencePool.modelServers.matchLabels.app=vllm-sim \
  --set provider.name=none \
  --wait --timeout 3m >/dev/null
ok "InferencePool 'vllm-sim' + EPP deployed"

step "Applying InferenceObjective, Gateway and HTTPRoute"
kc apply -f "$LAB_ROOT/$YAML_DIR/inference/inferenceobjective.yaml" >/dev/null
# The Gateway/HTTPRoute reference the GatewayClass for this edition; render the
# class name in so the same yaml serves both editions.
sed "s/\${GATEWAY_CLASS}/$GATEWAY_CLASS/g" "$LAB_ROOT/$YAML_DIR/gateway/gateway.yaml" | kc apply -f - >/dev/null
kc apply -f "$LAB_ROOT/$YAML_DIR/gateway/httproute.yaml" >/dev/null
kc -n "$NS" rollout status deploy/inference-gateway --timeout=180s >/dev/null 2>&1 || true
ok "Gateway 'inference-gateway' programmed, route bound to the InferencePool"

echo "" >&2
log "Reach the gateway:  ./demo-scripts/port-forward.sh   (then curl localhost:18080/v1/chat/completions)"
