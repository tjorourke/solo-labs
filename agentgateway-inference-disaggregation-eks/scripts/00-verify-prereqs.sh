#!/usr/bin/env bash
# Check the lab this one layers on is actually there and working.
#
#   ./scripts/00-verify-prereqs.sh
#
# It needs four things from agentgateway-inference-load-balancing-eks: the cluster, two
# GPU nodes, a working Gateway, and the two volumes with the weights already on them.
# The last one is why this lab is quick: nothing is downloaded again.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require kubectl; require aws
resolve_ctx

fail=0

step "the Gateway from the load-balancing lab"
if kc -n "$NS" get gateway inference-gateway >/dev/null 2>&1; then
  prog="$(kc -n "$NS" get gateway inference-gateway \
    -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)"
  [ "$prog" = "True" ] && ok "Gateway inference-gateway Programmed" \
    || { warn "Gateway exists but is not Programmed"; fail=1; }
else
  warn "no Gateway 'inference-gateway' in namespace $NS"
  fail=1
fi

step "two GPU nodes"
n=$(kc get nodes -l role=gpu \
  -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null \
  | grep -c '^1$' || true)
if [ "${n:-0}" -ge 2 ]; then
  ok "$n GPU nodes"
else
  warn "only ${n:-0} GPU node(s). Bring the pair up with:"
  warn "  $BASE_LAB/scripts/gpu.sh up"
  fail=1
fi

step "the weights, already on their volumes"
# Bound, not merely existing. A PVC in Pending looks fine in a `get pvc` skim and then
# leaves the prefill pod stuck with no useful event.
for pvc in weights-vllm-0 weights-vllm-1; do
  phase="$(kc -n "$NS" get pvc "$pvc" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [ "$phase" = "Bound" ]; then
    ok "$pvc Bound"
  else
    warn "$pvc is '${phase:-missing}'. This lab reuses the load-balancing lab's volumes"
    warn "so it does not re-download 62 GB. Run that lab's up first."
    fail=1
  fi
done

step "the Gateway API Inference Extension CRDs"
if kc get crd inferencepools.inference.networking.k8s.io >/dev/null 2>&1; then
  ok "InferencePool v1 CRD present"
else
  warn "InferencePool CRD missing — run $BASE_LAB/scripts/01-gateway.sh"
  fail=1
fi

echo >&2
[ "$fail" -eq 0 ] && ok "prerequisites met" \
  || die "prerequisites not met. Bring up agentgateway-inference-load-balancing-eks first."
