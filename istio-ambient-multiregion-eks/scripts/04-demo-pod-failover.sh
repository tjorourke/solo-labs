#!/usr/bin/env bash
# 04-demo-pod-failover.sh — demo 1: local pods die, the global service fails
# over cross-region, then returns when they come back. No DNS involved.
#
#   phase 1  eu-central client -> served by eu-central (PreferClose)
#   phase 2  scale eu-central region-echo to 0 -> served by eu-west
#   phase 3  scale back up -> traffic returns local
#
# Each phase is ASSERTED, not printed. This script used to only tail the client
# log and exit 0 whatever it said, which meant a mesh that had stopped failing
# over still reported a pass.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
CTX1="$(ctx_of "$NAME1" "$REGION1")"
[[ -n "$CTX1" ]] || die "missing kube context for $NAME1"

show() { kubectl --context "$CTX1" -n shop logs deploy/client --tail=4; }

# await_region <region> <timeout-sec> — wait for the client to be served by
# <region>. Reads only fresh lines (--since) so a stale log tail from the
# previous phase can never satisfy the next one.
await_region() {
  local want="$1" timeout="${2:-150}" end out
  end=$(( $(date +%s) + timeout ))
  while [[ $(date +%s) -lt $end ]]; do
    out="$(kubectl --context "$CTX1" -n shop logs deploy/client --since=10s 2>/dev/null || true)"
    if grep -q "\"region\": *\"$want\"" <<<"$out"; then
      return 0
    fi
    sleep 5
  done
  echo "--- last client output ---" >&2
  kubectl --context "$CTX1" -n shop logs deploy/client --tail=15 >&2 2>/dev/null || true
  return 1
}

step "Phase 1 — steady state (expect region: $REGION1)"
await_region "$REGION1" 90 || die "phase 1: client is not served by $REGION1 at steady state"
show
ok "phase 1: served locally by $REGION1"

step "Phase 2 — kill the local endpoints (scale region-echo to 0 in $REGION1)"
kubectl --context "$CTX1" -n shop scale deploy/region-echo --replicas=0 >/dev/null
kubectl --context "$CTX1" -n shop wait --for=delete pod -l app=region-echo --timeout=120s >/dev/null 2>&1 || true
echo "  ...waiting for failover to settle"
await_region "$REGION2" 150 \
  || die "phase 2: no failover to $REGION2 — the global service did not serve cross-region over the east-west gateways"
show
ok "phase 2: failed over cross-region to $REGION2"

step "Phase 3 — restore (scale back to 2)"
kubectl --context "$CTX1" -n shop scale deploy/region-echo --replicas=2 >/dev/null
kubectl --context "$CTX1" -n shop rollout status deploy/region-echo --timeout=180s >/dev/null
echo "  ...waiting for locality preference to reassert"
await_region "$REGION1" 150 \
  || die "phase 3: traffic did not return to $REGION1 — locality preference did not reassert after restore"
show
ok "phase 3: returned local to $REGION1"

ok "pod-level failover demonstrated: local -> remote -> local, zero client changes"
