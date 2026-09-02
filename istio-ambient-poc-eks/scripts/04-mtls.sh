#!/usr/bin/env bash
# 04-mtls.sh — scenario 1: in-cluster mTLS in EKS. Prove the traffic is HBONE
# with SPIFFE identities, then turn on STRICT and an L4 policy and watch a
# non-allowed identity get refused by ztunnel.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_aws; require_contexts; require_istioctl
C="$CLUSTER_A"

step "[$C] workloads ztunnel knows about in shop (PROTOCOL column = HBONE)"
"$ISTIOCTL" --context "$C" ztunnel-config workloads --workload-namespace "$APP_NS"

step "[$C] one request, then the ztunnel access log for it: source and destination identities"
kubectl --context "$C" -n "$APP_NS" exec deploy/frontend -- curl -s http://catalog.shop.svc.cluster.local:8080/; echo
sleep 2
kubectl --context "$C" -n istio-system logs ds/ztunnel --since=30s 2>/dev/null \
  | grep 'dst.service="catalog.shop' | grep -o 'src.identity="[^"]*".*dst.identity="[^"]*"' | tail -1 || true

step "[$C] the catalog workload certificate ztunnel holds (SPIFFE SAN, issuer chain, expiry)"
ZT="$(kubectl --context "$C" -n istio-system get pod -l app=ztunnel -o jsonpath='{.items[0].metadata.name}')"
"$ISTIOCTL" --context "$C" ztunnel-config certificate "$ZT.istio-system" | grep -E 'CERTIFICATE|catalog' | head -8

step "[$C] STRICT mTLS mesh-wide + L4 policy: only frontend may reach catalog"
show kubectl --context "$C" apply -f "$YAML_DIR/security/peer-auth-strict.yaml"
sed "s/TRUST_DOMAIN/$TRUST_DOMAIN_A/" "$YAML_DIR/security/authz-catalog.yaml" | kubectl --context "$C" apply -f -
kubectl --context "$C" apply -f "$YAML_DIR/security/rogue.yaml" >/dev/null
kubectl --context "$C" -n "$APP_NS" wait pod/rogue --for=condition=Ready --timeout=120s >/dev/null
sleep 3

step "[$C] frontend still works, rogue is refused at L4"
echo -n "  frontend -> catalog: "; kubectl --context "$C" -n "$APP_NS" exec deploy/frontend -- curl -s -o /dev/null -w '%{http_code}\n' -m5 http://catalog.shop.svc.cluster.local:8080/ || echo "failed"
echo -n "  rogue    -> catalog: "; kubectl --context "$C" -n "$APP_NS" exec rogue -- curl -s -o /dev/null -w '%{http_code}\n' -m5 http://catalog.shop.svc.cluster.local:8080/ || echo "connection refused (expected)"
sleep 2
kubectl --context "$C" -n istio-system logs ds/ztunnel --since=20s 2>/dev/null | grep -i 'rogue' | grep -io 'error="[^"]*"' | tail -1 | sed 's/^/  ztunnel: /' || true
