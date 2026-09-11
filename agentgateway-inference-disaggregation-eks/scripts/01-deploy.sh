#!/usr/bin/env bash
# Re-role the two cards as one prefill worker and one decode worker.
#
#   ./scripts/01-deploy.sh
#
# The order here is not cosmetic. The load-balancing lab's StatefulSet holds both
# ReadWriteOnce volumes, so it has to be scaled to zero and its pods actually GONE
# before the new Deployments can mount them. Apply them first and both pods sit in
# ContainerCreating on "Multi-Attach error for volume", which reads like a storage fault
# rather than a sequencing one.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require kubectl
resolve_ctx

step "releasing the volumes: scaling the load-balancing StatefulSet to zero"
if kc -n "$NS" get statefulset vllm >/dev/null 2>&1; then
  kc -n "$NS" scale statefulset vllm --replicas=0 >/dev/null
  # Wait for the pods to be gone, not for the scale command to return. The volume is
  # only detached once the pod object is deleted and the node has unmounted it.
  for _ in $(seq 1 60); do
    left=$(kc -n "$NS" get pods -l app=vllm --no-headers 2>/dev/null | wc -l | tr -d ' ')
    [ "${left:-0}" = "0" ] && break
    sleep 5
  done
  [ "${left:-0}" = "0" ] && ok "StatefulSet scaled to zero, volumes released" \
    || warn "pods still present after 5m; the next step may hit Multi-Attach"
else
  log "no StatefulSet 'vllm' — nothing to release"
fi

step "the llm-d Endpoint Picker and the P/D InferencePool"
kc apply -f "$LAB_ROOT/yaml/10-epp.yaml" >/dev/null
kc -n "$NS" rollout status deploy/pd-epp --timeout=300s >/dev/null
ok "pd-epp running"

step "prefill worker (card 1) and decode worker + sidecar (card 2)"
kc apply -f "$LAB_ROOT/yaml/00-prefill.yaml" -f "$LAB_ROOT/yaml/01-decode.yaml" >/dev/null
log "both reload from the volumes the other lab filled, so this is a load, not a download"
kc -n "$NS" rollout status deploy/vllm-prefill --timeout=1200s
kc -n "$NS" rollout status deploy/vllm-decode  --timeout=1200s
ok "both workers Ready"

step "pointing the route at the P/D pool"
kc apply -f "$LAB_ROOT/yaml/20-httproute.yaml" >/dev/null
sleep 2
kc -n "$NS" get httproute llm-route \
  -o jsonpath='{range .status.parents[*]}{.conditions[?(@.type=="ResolvedRefs")].status} {.conditions[?(@.type=="ResolvedRefs")].message}{"\n"}{end}' \
  | sed 's/^/    ResolvedRefs: /' >&2

step "confirming the picker loaded the disaggregation profiles"
# --allow-experimental-plugins is the trap: without it the EPP starts, reads the same
# config, logs no error, and runs a single default profile. Every request then serves
# monolithically and the only symptom is a prefill pod whose counters never move.
if kc -n "$NS" logs deploy/pd-epp --tail=300 2>/dev/null | grep -qiE 'disagg-profile-handler|prefill-filter'; then
  ok "disagg-profile-handler is loaded"
else
  warn "no sign of disagg-profile-handler in the EPP log."
  warn "Check --allow-experimental-plugins is set and the config mounted:"
  warn "  kc -n $NS logs deploy/pd-epp --tail=100"
  warn "  kc -n $NS get configmap pd-epp-config -o yaml"
fi

step "ready. Prove it with:  ./scripts/02-test.sh"
kc -n "$NS" get pods -l app=vllm-pd -o wide
