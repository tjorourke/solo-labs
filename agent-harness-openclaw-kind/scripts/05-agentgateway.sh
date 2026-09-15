#!/usr/bin/env bash
# 05-agentgateway.sh — install OSS agentgateway, put Anthropic behind it, and move the
# harness's model path onto the gateway.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
require_secrets
mkdir -p "$CAPTURES"

step "Gateway API ${GATEWAY_API_VERSION} and agentgateway ${AGENTGATEWAY_VERSION}"
kc apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" >/dev/null
helm --kube-context "$CTX" upgrade --install agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
  --namespace "$AGW_NS" --create-namespace --version "$AGENTGATEWAY_VERSION" --wait --timeout 3m >/dev/null
helm --kube-context "$CTX" upgrade --install agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --namespace "$AGW_NS" --version "$AGENTGATEWAY_VERSION" --wait --timeout 5m >/dev/null
kc get gatewayclass agentgateway >/dev/null
ok "gatewayclass agentgateway present"

step "Gateway ${GATEWAY_NAME}, Anthropic backend and /v1 route"
kc -n "$AGW_NS" create secret generic anthropic-secret \
  --from-literal=Authorization="$ANTHROPIC_API_KEY" --dry-run=client -o yaml | kc apply -f - >/dev/null
kc apply -f "$YAML/40-gateway.yaml" -f "$YAML/41-anthropic-backend.yaml"
kc -n "$AGW_NS" wait gateway/"$GATEWAY_NAME" --for=condition=Programmed --timeout=180s >/dev/null
wait_deploy "$AGW_NS" "$GATEWAY_NAME" 180s
ok "gateway programmed"

step "direct check: one chat.completions call through the gateway, with no provider key on the client"
gateway_pf
resp=$(curl -sS --max-time 60 "http://127.0.0.1:${GATEWAY_PORT}/v1/chat/completions" \
  -H 'content-type: application/json' \
  -d "{\"model\":\"${MODEL_NAME}\",\"max_tokens\":32,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the single word gateway.\"}]}")
printf '%s\n' "$resp" | python3 -m json.tool > "$CAPTURES/gateway-direct-call.json" 2>/dev/null || printf '%s\n' "$resp" > "$CAPTURES/gateway-direct-call.json"
printf '%s' "$resp" | grep -q '"chat.completion"' || die "gateway call failed: $resp"
ok "gateway answered: $(printf '%s' "$resp" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["model"], "|", d["choices"][0]["message"]["content"].strip())')"

step "ModelConfig agentgateway-model, then recreate the harness on it"
kc apply -f "$YAML/42-model-config.yaml"
# Changing modelConfigRef in place regenerates the ActorTemplate and its golden snapshot, but
# kagent 0.10.1 keeps the harness's one shared actor (ahr-kagent-openclaw-lab) running with
# the config it was born with; only the harness finalizer deletes it. So the switch is a
# delete and re-create, and the OpenClaw workspace inside that actor goes with it.
if kc -n "$NS" get agentharness "$HARNESS" >/dev/null 2>&1; then
  kc -n "$NS" delete agentharness "$HARNESS" --timeout=300s >/dev/null
  for _ in $(seq 1 60); do kc -n "$NS" get actortemplates.ate.dev "$HARNESS" >/dev/null 2>&1 || break; sleep 3; done
fi
kc apply -f "$YAML/43-openclaw-harness-gateway.yaml"
for _ in $(seq 1 120); do [[ "$(condition "agentharness/${HARNESS}" Ready)" == True ]] && break; sleep 5; done
[[ "$(condition "agentharness/${HARNESS}" Ready)" == True ]] || die "harness not Ready after the ModelConfig change: $(condition_msg "agentharness/${HARNESS}" Ready)"
kc -n "$NS" get actortemplates.ate.dev "$HARNESS" -o jsonpath='{.spec.containers[0].command[2]}' \
  | grep -o "echo '[^']*' | base64 -d" | head -1 | sed "s/echo '//; s/' | base64 -d//" | base64 -d \
  | python3 -m json.tool > "$CAPTURES/openclaw-json-gateway.json"
kc -n "$NS" get actortemplates.ate.dev "$HARNESS" -o yaml > "$CAPTURES/actor-template-gateway.yaml"
log "generated openclaw.json now: $(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["models"]["providers"]["openai"]["baseUrl"])' "$CAPTURES/openclaw-json-gateway.json")"
ok "harness ${HARNESS} uses ModelConfig agentgateway-model"
