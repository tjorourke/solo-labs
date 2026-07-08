#!/usr/bin/env bash
# health-check.sh — non-fatal PASS/FAIL sweep of the standup.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

pass=0; fail=0
chk() { local msg="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$msg"; pass=$((pass+1)); else warn "$msg"; fail=$((fail+1)); fi; }

gw_programmed() {
  kc -n "$NS" get gateway inference-gateway \
    -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null | grep -q True
}
route_accepted() {
  kc -n "$NS" get httproute llm-route \
    -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null | grep -q True
}

step "Health check ($AGW_EDITION)"
chk "cluster reachable"            kc get nodes
chk "GatewayClass $GATEWAY_CLASS"  kc get gatewayclass "$GATEWAY_CLASS"
chk "agentgateway controller up"   kc -n "$AGW_NS" get deploy enterprise-agentgateway
chk "InferencePool vllm-sim"        kc -n "$NS" get inferencepool vllm-sim
chk "Endpoint Picker up"            kc -n "$NS" get deploy vllm-sim-epp
chk "model server pool-a"           kc -n "$NS" get deploy vllm-pool-a
chk "model server pool-b"           kc -n "$NS" get deploy vllm-pool-b
chk "gateway programmed"            gw_programmed
chk "route accepted"               route_accepted

step "Result: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
