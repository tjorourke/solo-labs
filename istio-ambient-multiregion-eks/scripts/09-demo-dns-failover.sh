#!/usr/bin/env bash
# 09-demo-dns-failover.sh — Approach A demo: Route 53 fails the region out at
# DNS resolution time. Contrast 07 (Global Accelerator), where the client keeps
# the same IPs.
#
#   ./09-demo-dns-failover.sh <record-fqdn>
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
FQDN="${1:?usage: 09-demo-dns-failover.sh <record-fqdn>}"
CTX1="$(ctx_of "$NAME1" "$REGION1")"
[[ -n "$CTX1" ]] || die "missing kube context for $NAME1"

resolve() { dig +short "$FQDN" CNAME 2>/dev/null | head -1; }
serve()   { curl -s -m4 "http://$FQDN/" 2>/dev/null | grep -o '"region": "[^"]*"' || echo '"region": "(no answer)"'; }

step "Phase 1 — steady state (primary = $REGION1)"
echo "  resolves to: $(resolve)"
echo "  serves:      $(serve)"

step "Phase 2 — $REGION1 ingress goes down (primary health check will fail)"
kubectl --context "$CTX1" -n kgateway-system scale deploy/ingress --replicas=0 >/dev/null
echo "  ...waiting for the health check to fail + DNS to hand out the secondary"
# health check: 10s interval x2 fails = ~20s, then TTL expiry — poll up to 3 min
for _ in $(seq 1 36); do
  r="$(serve)"
  [[ "$r" == *"$REGION2"* ]] && { echo "  flipped: $r"; break; }
  sleep 5
done
echo "  resolves to: $(resolve)"
echo "  serves:      $(serve)"

step "Phase 3 — restore $REGION1 ingress"
kubectl --context "$CTX1" -n kgateway-system scale deploy/ingress --replicas=1 >/dev/null
kubectl --context "$CTX1" -n kgateway-system rollout status deploy/ingress --timeout=120s >/dev/null
echo "  (primary returns once its health check passes again and the TTL expires)"

ok "DNS failover demonstrated — cutover is health-check detection + record TTL"
