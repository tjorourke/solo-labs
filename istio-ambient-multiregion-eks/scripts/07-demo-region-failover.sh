#!/usr/bin/env bash
# 07-demo-region-failover.sh — demo 2: region unreachable, Global Accelerator
# cuts to the healthy region.
#
# This is the EDGE failover (contrast 04, which is the MESH failover). We take
# down one region's ingress proxy entirely — GA's health check on the NLB (:80)
# fails, and the anycast address serves only the surviving region within
# ~20-30s. No DNS, no TTLs.
#
#   ./07-demo-region-failover.sh <global-accelerator-dns>
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
GA="${1:?usage: 07-demo-region-failover.sh <global-accelerator-dns>}"
CTX1="$(ctx_of "$NAME1" "$REGION1")"; CTX2="$(ctx_of "$NAME2" "$REGION2")"
[[ -n "$CTX1" && -n "$CTX2" ]] || die "missing kube contexts"

sample() { # sample <label> — resilient to timeouts (never trips set -e)
  echo "── $1 (20 requests via the GA anycast address) ──"
  { for _ in $(seq 1 20); do
      curl -s -m3 "http://$GA/" 2>/dev/null | grep -o '"region": "[^"]*"' || echo '"region": "(timeout)"'
      sleep 0.5
    done; } | sort | uniq -c || true
}
served_region() { curl -s -m3 "http://$GA/" 2>/dev/null | grep -o '"region": "[^"]*"' | cut -d'"' -f4 || true; }
# poll until GA serves ONLY the given region (or timeout) — returns when flipped
wait_flip() { # wait_flip <expected-region> <max-secs>
  local want="$1" max="$2" t=0
  while (( t < max )); do
    local r; r="$(served_region)"
    [[ "$r" == "$want" ]] && { echo "  flipped to $want after ${t}s"; return 0; }
    sleep 5; t=$((t+5))
  done
  echo "  did not flip to $want within ${max}s"; return 1
}

step "Phase 1 — steady state: GA serves this client from its nearest edge"
sample "before"

# Global Accelerator routes each client to its NEAREST healthy region. To SEE a
# failover we must take down the region THIS client is actually being served
# from, not an arbitrary one.
CUR="$(served_region)"
if [[ "$CUR" == "$REGION1" ]]; then DOWN_CTX="$CTX1"; DOWN_REGION="$REGION1"; UP_REGION="$REGION2"
else DOWN_CTX="$CTX2"; DOWN_REGION="$REGION2"; UP_REGION="$REGION1"; fi

step "Phase 2 — $DOWN_REGION ingress goes down (the region GA is serving us)"
kubectl --context "$DOWN_CTX" -n kgateway-system scale deploy/ingress --replicas=0 >/dev/null
echo "  ...polling until GA fails $DOWN_REGION and serves $UP_REGION (health check + propagation)"
wait_flip "$UP_REGION" 180 || true
sample "during outage (expect only $UP_REGION)"

step "Phase 3 — restore $DOWN_REGION ingress"
kubectl --context "$DOWN_CTX" -n kgateway-system scale deploy/ingress --replicas=1 >/dev/null
kubectl --context "$DOWN_CTX" -n kgateway-system rollout status deploy/ingress --timeout=120s >/dev/null
echo "  ...waiting for GA to mark $DOWN_REGION healthy again"; sleep 30
sample "after restore"

ok "region-level failover via Global Accelerator: no DNS, cutover in ~20-30s on health-check failure"
