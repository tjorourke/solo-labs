#!/usr/bin/env bash
# 05-crosscluster.sh — scenario 2: EKS to EKS. The global hostname, flat-network
# failover to the other cluster, and identity-based policy across clusters.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_aws; require_contexts; require_istioctl
A="$CLUSTER_A"; B="$CLUSTER_B"

step "Shared services the mesh publishes (from istioctl multicluster check)"
"$ISTIOCTL" multicluster check --contexts "$A,$B" 2>/dev/null | grep -iE 'shared|mesh.internal|catalog' | head -6 || true

step "[$A frontend] 6 calls to the GLOBAL hostname: endpoints from BOTH clusters (flat network, one endpoint pool)"
for _ in 1 2 3 4 5 6; do
  kubectl --context "$A" -n "$APP_NS" exec deploy/frontend -- curl -s -m5 http://catalog.shop.mesh.internal:8080/; echo
done

step "Policy for the linked mesh: allow the frontend identity from BOTH clusters"
show kubectl --context "$A" apply -f "$YAML_DIR/security/authz-catalog-multicluster.yaml"
kubectl --context "$B" apply -f "$YAML_DIR/security/peer-auth-strict.yaml" >/dev/null
kubectl --context "$B" apply -f "$YAML_DIR/security/authz-catalog-multicluster.yaml" >/dev/null
ok "same policy in both clusters, STRICT in both"

step "[$A] scale catalog to 0: the same hostname is now served by $B over the east-west gateways"
kubectl --context "$A" -n "$APP_NS" scale deploy/catalog --replicas=0 >/dev/null
sleep 10
for _ in 1 2 3 4; do
  kubectl --context "$A" -n "$APP_NS" exec deploy/frontend -- curl -s -m5 http://catalog.shop.mesh.internal:8080/; echo
done
echo "  [$B ztunnel] the inbound identity is $A's frontend, arriving through the east-west gateway:"
kubectl --context "$B" -n istio-system logs ds/ztunnel --since=40s 2>/dev/null \
  | grep 'dst.service="catalog.shop' | grep -o 'src.identity="[^"]*"' | sort | uniq -c | tail -3 | sed 's/^/   /' || true

step "[$A] scale back: eks-a endpoints rejoin the pool"
kubectl --context "$A" -n "$APP_NS" scale deploy/catalog --replicas=2 >/dev/null
kubectl --context "$A" -n "$APP_NS" rollout status deploy/catalog --timeout=120s >/dev/null
sleep 5
for _ in 1 2 3; do
  kubectl --context "$A" -n "$APP_NS" exec deploy/frontend -- curl -s -m5 http://catalog.shop.mesh.internal:8080/; echo
done
