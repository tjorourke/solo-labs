#!/usr/bin/env bash
# Check the environment this lab needs before changing anything.
#
#   ./scripts/00-verify-prereqs.sh
#
# This lab builds nothing. It needs the model-routing lab already working, and stops here
# rather than failing three steps later with an error about the wrong thing.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/scripts/lib-context.sh"
resolve_ctx
kubectl() { command kubectl --context "$CTX" "$@"; }

fail=0
ok()   { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; fail=1; }

echo "context: $CTX"
echo

for d in vllm vllm-qwen; do
  if [ "$(kubectl get deploy "$d" -n models -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" = "1" ]; then
    ok "$d is serving"
  else
    bad "$d is not ready. If the GPU nodes are scaled to zero, run the model-routing lab's ./scripts/gpu.sh up"
  fi
done

if [ "$(kubectl get deploy semantic-router -n agentgateway-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" = "1" ]; then
  ok "semantic-router is running"
else
  bad "semantic-router is not ready"
fi

if [ "$(kubectl get gateway model-gateway -n agentgateway-system \
        -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)" = "True" ]; then
  ok "model-gateway is Programmed"
else
  bad "model-gateway is not Programmed"
fi

# The ExtProc policy has to be the semantic one. If that lab was left on the keyword
# classifier the router is never called, and every result below would be the regex.
if kubectl get agentgatewaypolicy extract-model-internal -n agentgateway-system \
     -o jsonpath='{.spec.traffic.extProc.backendRef.name}' 2>/dev/null | grep -q semantic-router; then
  ok "the gateway is calling the semantic router"
else
  bad "the gateway is on the keyword classifier. Apply that lab's yaml-oss/80 and 81 first."
fi

echo
if [ "$fail" -ne 0 ]; then
  echo "The model-routing lab is not ready. Fix the above before deploying this one." >&2
  exit 1
fi
echo "Ready."
