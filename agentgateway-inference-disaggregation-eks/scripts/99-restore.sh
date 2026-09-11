#!/usr/bin/env bash
# Put the cluster back the way the load-balancing lab left it.
#
#   ./scripts/99-restore.sh
#
# This lab creates no cloud resources, so there is nothing here that costs money. What it
# does do is take over both GPU cards and the route, and leaving it half-unwound is how
# the other lab appears to break later for no reason.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
resolve_ctx

step "removing the P/D workers"
kc delete -f "$LAB_ROOT/yaml/00-prefill.yaml" -f "$LAB_ROOT/yaml/01-decode.yaml" \
  --ignore-not-found --timeout=180s >/dev/null 2>&1 || true
# Same Multi-Attach trap in reverse: the StatefulSet cannot mount the volumes until
# these pods are really gone, not merely marked for deletion.
for _ in $(seq 1 60); do
  left=$(kc -n "$NS" get pods -l app=vllm-pd --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [ "${left:-0}" = "0" ] && break
  sleep 5
done
ok "P/D workers gone, volumes released"

step "removing the llm-d Endpoint Picker and the P/D pool"
kc delete -f "$LAB_ROOT/yaml/10-epp.yaml" --ignore-not-found --timeout=120s >/dev/null 2>&1 || true
ok "removed"

step "restoring the load-balancing lab's route and replicas"
if [ -d "$BASE_LAB" ]; then
  # The route first: pointing it back before the pool exists is harmless and briefly
  # unresolved, whereas leaving it on a pool that has just been deleted is a 500 for
  # every request in the meantime.
  kc apply -f "$BASE_LAB/yaml/11-httproute-pool.yaml" >/dev/null
  kc -n "$NS" scale statefulset vllm --replicas=2 >/dev/null 2>&1 || true
  log "waiting for both replicas to reload from their volumes"
  kc -n "$NS" rollout status statefulset/vllm --timeout=1200s || \
    warn "replicas not Ready yet — watch: kc -n $NS get pods -l app=vllm -w"
  ok "back to two replicas of one model behind the InferencePool"
else
  warn "could not find the load-balancing lab at $BASE_LAB"
  warn "Restore it by hand:  kubectl -n $NS scale statefulset vllm --replicas=2"
  warn "                     kubectl apply -f <that lab>/yaml/11-httproute-pool.yaml"
fi

step "state now"
kc -n "$NS" get pods,httproute,inferencepool
