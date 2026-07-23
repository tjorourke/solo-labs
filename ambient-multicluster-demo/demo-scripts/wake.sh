#!/usr/bin/env bash
# wake.sh — heal the standup after the laptop has slept.
#
# The platform (both kind clusters, ambient, agentgateway, Gloo UI) survives a
# reboot/sleep, but ambient leaf certs are short-lived (24h TTL). After a long
# sleep the wall-clock jumps past their expiry and HBONE mTLS breaks: ztunnel
# handshakes fail with CertificateExpired, the east-west gateways serve stale
# certs, istiod holds a dead peering connection, and new agentgateway pods
# crashloop on an expired xDS cert. The standup is fine — only the certs are
# stale. Restarting the cert-dependent control planes forces fresh leafs and
# re-establishes peering in ~2 min.
#
# Run once at the start of a demo day (or whenever the notebook Connect cell
# is red):   ./demo-scripts/wake.sh
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../scripts/lib.sh"

IC="$ISTIOCTL"; command -v "$IC" >/dev/null 2>&1 || IC="istioctl"

if "$IC" --context "$CLUSTER1" multicluster check 2>&1 \
     | grep -q "Peers Check: all clusters connected"; then
  echo "✓ already peered over HBONE — nothing to heal"
  exit 0
fi

echo "… refreshing certs — restarting cert-dependent control planes on both clusters"

restart_one() {
  local ctx=$1 ns=$2 kind=$3 name=$4
  if kubectl --context "$ctx" -n "$ns" get "$kind/$name" >/dev/null 2>&1; then
    kubectl --context "$ctx" -n "$ns" rollout restart "$kind/$name" >/dev/null
    echo "  [$ctx] restarted $ns/$name"
  fi
}

for CTX in "$CLUSTER1" "$CLUSTER2"; do
  restart_one "$CTX" istio-system deployment istiod
  restart_one "$CTX" istio-system daemonset ztunnel
  restart_one "$CTX" istio-eastwest deployment istio-eastwest
  restart_one "$CTX" agentgateway-system deployment enterprise-agentgateway
done

for CTX in "$CLUSTER1" "$CLUSTER2"; do
  kubectl --context "$CTX" -n istio-system rollout status deploy/istiod --timeout=180s >/dev/null
  kubectl --context "$CTX" -n istio-system rollout status ds/ztunnel --timeout=180s >/dev/null
done

echo "… waiting for peering to re-establish (~2 min)"
for _ in $(seq 1 24); do
  if "$IC" --context "$CLUSTER1" multicluster check 2>&1 \
       | grep -q "Peers Check: all clusters connected"; then
    echo "✓ peering re-established"
    exit 0
  fi
  sleep 10
done
echo "✗ still not peered — full rebuild: ./setup.sh" >&2
exit 1
