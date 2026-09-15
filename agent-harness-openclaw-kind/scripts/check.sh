#!/usr/bin/env bash
# check.sh — the lab's acceptance table. Every line is a real check against the running
# stack; the chat checks send prompts and cost model tokens.
#   ./scripts/quick.sh test            everything
#   ./scripts/check.sh --no-chat       skip the prompts (state + wiring only)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
mkdir -p "$CAPTURES"
chat=1; [[ "${1:-}" == "--no-chat" ]] && chat=0
pass=0; fail=0; skip=0
report=()
result() { # result PASS|FAIL|SKIP "text"
  case "$1" in PASS) pass=$((pass+1));; FAIL) fail=$((fail+1));; SKIP) skip=$((skip+1));; esac
  report+=("[$1] $2"); printf '[%s] %s\n' "$1" "$2" >&2
}
check() { # check "label" command...
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then result PASS "$label"; else result FAIL "$label"; fi
}

step "standalone OpenClaw 2.0"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$BASELINE_CONTAINER"; then
  v=$(docker exec "$BASELINE_CONTAINER" node dist/index.js --version 2>/dev/null || true)
  if [[ "$v" == *"$OPENCLAW_VERSION"* ]]; then result PASS "OpenClaw standalone version = ${OPENCLAW_VERSION} ($v)"; else result FAIL "OpenClaw standalone version: $v"; fi
  [[ -f "$RUNTIME/openclaw/workspace/lab-marker.txt" ]] && result PASS "standalone workspace marker written by the agent" || result SKIP "standalone workspace marker (run: quick.sh baseline)"
  grep -q BLUE-HERON "$RUNTIME/openclaw/workspace/MEMORY.md" 2>/dev/null && result PASS "standalone MEMORY.md holds the code name" || result SKIP "standalone memory test (run: quick.sh baseline)"
else
  result SKIP "OpenClaw standalone baseline not running (./scripts/quick.sh baseline)"
fi

step "Agent Substrate and kagent"
kc cluster-info >/dev/null 2>&1 || die "cluster ${CTX} not reachable"
check "Substrate control plane pods Available" kc -n "$ATE_NS" wait deploy --all --for=condition=Available --timeout=5s
kc -n "$ATE_NS" exec valkey-cluster-0 -- valkey-cli CLUSTER INFO 2>/dev/null | tr -d '\r' | grep -qx cluster_state:ok && result PASS "Valkey cluster_state:ok" || result FAIL "Valkey cluster_state"
workers=$(substrate_status 2>/dev/null | python3 -c 'import sys,json; print(len(json.load(sys.stdin)["data"]["workers"]))' 2>/dev/null || echo 0)
[[ "$workers" -ge 2 ]] && result PASS "WorkerPool has >= 2 workers registered ($workers)" || result FAIL "workers registered: $workers"
[[ "$(substrate_status 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin)["data"]["enabled"])' 2>/dev/null)" == True ]] && result PASS "kagent controller reports substrate enabled" || result FAIL "kagent substrate status"
kc get crd agentharnesses.kagent.dev -o json 2>/dev/null | grep -q '"hermes"' && result PASS "AgentHarness CRD backend enum includes openclaw and hermes" || result FAIL "AgentHarness CRD backend enum"

step "the harness"
[[ "$(condition "agentharness/${HARNESS}" Accepted)" == True ]] && result PASS "AgentHarness Accepted=True" || result FAIL "AgentHarness Accepted"
[[ "$(condition "agentharness/${HARNESS}" Ready)" == True ]] && result PASS "AgentHarness Ready=True" || result FAIL "AgentHarness Ready: $(condition_msg "agentharness/${HARNESS}" Ready)"
[[ "$(kc -n "$NS" get actortemplates.ate.dev "$HARNESS" -o jsonpath='{.status.phase}' 2>/dev/null)" == Ready ]] && result PASS "ActorTemplate phase Ready" || result FAIL "ActorTemplate phase"
img=$(kc -n "$NS" get actortemplates.ate.dev "$HARNESS" -o jsonpath='{.spec.containers[0].image}' 2>/dev/null)
[[ "$img" == *acp-sandbox-openclaw@sha256:* ]] && result PASS "backend image is digest-pinned acp-sandbox-openclaw" || result FAIL "backend image: $img"
# The env var kagent injects: with the gateway ModelConfig it must come from the placeholder Secret.
keysrc=$(kc -n "$NS" get actortemplates.ate.dev "$HARNESS" -o jsonpath='{.spec.containers[0].env[?(@.name=="OPENAI_API_KEY")].valueFrom.secretKeyRef.name}' 2>/dev/null)
mc=$(kc -n "$NS" get agentharness "$HARNESS" -o jsonpath='{.spec.modelConfigRef}')
if [[ "$mc" == agentgateway-model ]]; then
  [[ "$keysrc" == agentgateway-placeholder ]] && result PASS "actor env OPENAI_API_KEY comes from the placeholder Secret; no provider key in the actor" || result FAIL "actor env key source: $keysrc"
  base=$(kc -n "$NS" get actortemplates.ate.dev "$HARNESS" -o jsonpath='{.spec.containers[0].command[2]}' | grep -o "echo '[^']*' | base64 -d" | head -1 | sed "s/echo '//; s/' | base64 -d//" | base64 -d | python3 -c 'import sys,json; print(json.load(sys.stdin)["models"]["providers"]["openai"]["baseUrl"])' 2>/dev/null)
  [[ "$base" == "http://${GATEWAY_HOST}/v1" ]] && result PASS "generated openclaw.json baseUrl = http://${GATEWAY_HOST}/v1" || result FAIL "generated baseUrl: $base"
else
  result SKIP "harness still on ModelConfig ${mc} (05-agentgateway.sh moves it)"
fi

step "agentgateway"
if kc -n "$AGW_NS" get gateway "$GATEWAY_NAME" >/dev/null 2>&1; then
  [[ "$(kc -n "$AGW_NS" get gateway "$GATEWAY_NAME" -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}')" == True ]] && result PASS "Gateway ${GATEWAY_NAME} Programmed" || result FAIL "Gateway ${GATEWAY_NAME} not Programmed"
  gateway_pf
  tools=$(python3 "$SCRIPT_DIR/mcp-list.py" "http://127.0.0.1:${GATEWAY_PORT}/mcp" 2>/dev/null | sort | tr '\n' ' ')
  [[ "$tools" == "k8s_describe_resource k8s_get_events k8s_get_pod_logs k8s_get_resources " ]] && result PASS "gateway /mcp publishes exactly the 4 read tools" || result FAIL "gateway /mcp tools: $tools"
  # count model requests seen by the gateway so far, to compare after the chat
  before=$(kc -n "$AGW_NS" logs deploy/"$GATEWAY_NAME" --since=24h 2>/dev/null | grep -c 'http.path=/v1/chat/completions' || true)
else
  result SKIP "agentgateway not installed"
fi

if [[ $chat -eq 1 ]]; then
  step "chat through kagent (ACP)"
  export HARNESS NS CONTROLLER_URL CAPTURES
  controller_pf
  marker="HARNESS-OK-$(date +%s)"
  out=$(python3 "$SCRIPT_DIR/acp.py" --quiet --capture check-chat "Write a file check/marker.txt in your workspace containing exactly ${marker} and reply with only its contents." 2>&1) && [[ "$out" == *"$marker"* ]] \
    && result PASS "OpenClaw chat through kagent succeeds (workspace write)" || result FAIL "chat: ${out: -200}"
  # A new kagent session is a new ACP session inside the same shared actor.
  out=$(python3 "$SCRIPT_DIR/acp.py" --quiet --capture check-state "Read check/marker.txt in your workspace and reply with only its exact contents. If it does not exist reply MISSING." 2>&1)
  [[ "$out" == *"$marker"* ]] && result PASS "workspace written in one session is readable from a new session" || result FAIL "workspace persistence: ${out: -200}"
  if kc -n "$AGW_NS" get gateway "$GATEWAY_NAME" >/dev/null 2>&1 && [[ "$mc" == agentgateway-model ]]; then
    after=$(kc -n "$AGW_NS" logs deploy/"$GATEWAY_NAME" --since=24h 2>/dev/null | grep -c 'http.path=/v1/chat/completions' || true)
    [[ "$after" -gt "${before:-0}" ]] && result PASS "model requests traversed agentgateway (${before:-0} -> ${after} chat.completions)" || result FAIL "no new chat.completions seen at the gateway"
    out=$(python3 "$SCRIPT_DIR/acp.py" --quiet --capture check-mcp-allowed "Using only your kubernetes MCP tools, list the pods in namespace sre-lab that are not Running or have restarted more than three times. One line per pod: name, phase, restarts. Do not make changes." 2>&1)
    [[ "$out" == *checkout* && "$out" == *search* ]] && result PASS "approved MCP read tool succeeds (sre-lab investigated)" || result FAIL "mcp read: ${out: -300}"
    out=$(python3 "$SCRIPT_DIR/acp.py" --quiet --capture check-mcp-denied "Restart the checkout deployment in sre-lab using your kubernetes MCP tools to fix it. If you have no tool that can do that, say exactly NO-WRITE-TOOL and name the tools you do have." 2>&1)
    gen=$(kc -n "$SRE_NS" get deploy checkout -o jsonpath='{.metadata.generation}' 2>/dev/null)
    restarted=$(kc -n "$SRE_NS" get deploy checkout -o jsonpath='{.spec.template.metadata.annotations.kubectl\.kubernetes\.io/restartedAt}' 2>/dev/null)
    [[ -z "$restarted" && "$gen" == 1 && "$out" == *NO-WRITE-TOOL* ]] && result PASS "denied path: no write tool reached the cluster, checkout untouched" || result FAIL "denied path: gen=$gen restartedAt=$restarted out=${out: -200}"
  fi
fi

printf '\n' >&2
for line in "${report[@]}"; do printf '%s\n' "$line"; done | tee "$CAPTURES/validation.txt"
printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip" | tee -a "$CAPTURES/validation.txt"
[[ $fail -eq 0 ]]
