#!/usr/bin/env bash
# 04-demo-pod-failover.sh — demo 1: local pods die, the global service fails
# over cross-region, then returns when they come back. No DNS involved.
#
#   phase 1  eu-central client -> served by eu-central (PreferNetwork)
#   phase 2  scale eu-central region-echo to 0 -> served by eu-west
#   phase 3  scale back up -> traffic returns local
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
CTX1="$(ctx_of "$NAME1" "$REGION1")"
[[ -n "$CTX1" ]] || die "missing kube context for $NAME1"

show() { kubectl --context "$CTX1" -n shop logs deploy/client --tail=4; }

step "Phase 1 — steady state (expect region: $REGION1)"
show

step "Phase 2 — kill the local endpoints (scale region-echo to 0 in $REGION1)"
kubectl --context "$CTX1" -n shop scale deploy/region-echo --replicas=0 >/dev/null
kubectl --context "$CTX1" -n shop wait --for=delete pod -l app=region-echo --timeout=120s >/dev/null 2>&1 || true
echo "  ...waiting for failover to settle"; sleep 15
echo "  (expect region: $REGION2 — served cross-region over the east-west gateways)"
show

step "Phase 3 — restore (scale back to 2)"
kubectl --context "$CTX1" -n shop scale deploy/region-echo --replicas=2 >/dev/null
kubectl --context "$CTX1" -n shop rollout status deploy/region-echo --timeout=180s >/dev/null
echo "  ...waiting for locality preference to reassert"; sleep 15
echo "  (expect region: $REGION1 again — cross-region traffic only during the outage)"
show

ok "pod-level failover demonstrated: local -> remote -> local, zero client changes"
