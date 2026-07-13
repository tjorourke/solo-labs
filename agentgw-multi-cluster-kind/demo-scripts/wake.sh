#!/usr/bin/env bash
# wake.sh — heal the standup after the laptop has slept.
#
# The platform (both kind clusters, Istio ambient, agentgateway) survives a
# reboot/sleep, but Solo ambient leaf certs are short-lived (24h TTL). After a
# long sleep the wall-clock jumps past their expiry and the control-plane
# components keep serving now-expired certs instead of rotating cleanly. That
# breaks HBONE mTLS: ztunnel handshakes fail with CertificateExpired, the
# eastwest gateways serve stale certs, istiod holds a dead cross-cluster peering
# connection (PeerConnected: False), and any NEW agentgateway pod crashloops
# because its xDS cert is expired. connect.sh then reports "clusters not peered".
#
# The standup is fine — only the certs are stale. Restarting the cert-dependent
# control planes on both clusters forces fresh leaf certs and re-establishes
# peering, in ~1 min, without the ~5-15 min full standup (scripts/quick.sh).
#
# Run this once at the start of a demo day (or whenever connect.sh is red):
#   ./demo-scripts/wake.sh
set -Eeuo pipefail
CLUSTER1="${CLUSTER1:-kind-east-ag}"
CLUSTER2="${CLUSTER2:-kind-west-ag}"
export PATH="$HOME/.gloo-mesh/bin:$PATH"

echo "east = $CLUSTER1   west = $CLUSTER2"

# Fast path: already peered → nothing to do.
if istioctl --context "$CLUSTER1" multicluster check 2>&1 \
     | grep -q "Peers Check: all clusters connected"; then
  echo "✓ already peered over HBONE — nothing to heal"
  exit 0
fi

echo "… refreshing certs — restarting cert-dependent control planes on both clusters"

# (namespace, workload) pairs to bounce. istiod re-fetches the peering cert and
# re-dials the peer; ztunnel + eastwest re-issue HBONE leaf certs; the
# agentgateway control plane re-issues the xDS cert new gateway pods depend on.
restart_one() {
  local ctx=$1 ns=$2 kind=$3 name=$4
  if kubectl --context "$ctx" -n "$ns" get "$kind/$name" >/dev/null 2>&1; then
    kubectl --context "$ctx" -n "$ns" rollout restart "$kind/$name" >/dev/null 2>&1 \
      && echo "  [${ctx#kind-}] restarted $kind/$name"
  fi
}

for CTX in "$CLUSTER1" "$CLUSTER2"; do
  restart_one "$CTX" istio-system     deploy istiod-gloo
  restart_one "$CTX" istio-system     ds     ztunnel
  restart_one "$CTX" istio-eastwest   deploy istio-eastwest
  restart_one "$CTX" agentgateway-system deploy enterprise-agentgateway
done

echo "… waiting for control planes to become ready"
for CTX in "$CLUSTER1" "$CLUSTER2"; do
  kubectl --context "$CTX" -n istio-system       rollout status deploy/istiod-gloo   --timeout=180s >/dev/null 2>&1 || true
  kubectl --context "$CTX" -n istio-system       rollout status ds/ztunnel           --timeout=180s >/dev/null 2>&1 || true
  kubectl --context "$CTX" -n istio-eastwest     rollout status deploy/istio-eastwest --timeout=180s >/dev/null 2>&1 || true
  kubectl --context "$CTX" -n agentgateway-system rollout status deploy/enterprise-agentgateway --timeout=180s >/dev/null 2>&1 || true
done

echo "… waiting for cross-cluster peering to converge (istiod re-dials the peer — can take ~2 min)"
for _ in $(seq 1 40); do
  if istioctl --context "$CLUSTER1" multicluster check 2>&1 \
       | grep -q "Peers Check: all clusters connected"; then
    echo "✓ clusters peered over HBONE — ready to demo"
    exit 0
  fi
  sleep 5
done

echo "✗ still not peered after cert refresh — inspect with:" >&2
echo "    istioctl --context $CLUSTER1 multicluster check --verbose" >&2
echo "  if the platform itself is gone, rebuild with scripts/quick.sh" >&2
exit 1
