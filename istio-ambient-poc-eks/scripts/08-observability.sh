#!/usr/bin/env bash
# 08-observability.sh — scenario 6: the Gloo UI (Solo Enterprise for Istio
# management plane) on eks-a with eks-b registered, so one graph shows both
# clusters, the VM and every mTLS edge. Plus the raw ztunnel metrics.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require helm; require dig; require jq
require_license; require_aws; require_contexts
A="$CLUSTER_A"; B="$CLUSTER_B"
LIC="${GLOO_PLATFORM_LICENSE_KEY:-$SOLO_ISTIO_LICENSE_KEY}"
ADMIN_CIDR="${ADMIN_CIDR:-$(curl -s -m5 https://checkip.amazonaws.com | tr -d '\n')/32}"

helm repo add gloo-platform https://storage.googleapis.com/gloo-platform/helm-charts >/dev/null 2>&1 || true
helm repo update gloo-platform >/dev/null

step "[$A] Gloo Platform $GLOO_PLATFORM_VERSION: CRDs, register $A, management plane + UI"
kubectl --context "$A" create namespace "$GLOO_MESH_NS" --dry-run=client -o yaml | kubectl --context "$A" apply -f - >/dev/null
helm --kube-context "$A" upgrade -i gloo-platform-crds gloo-platform/gloo-platform-crds \
  -n "$GLOO_MESH_NS" --version "$GLOO_PLATFORM_VERSION" --wait --timeout 5m >/dev/null
# register the local cluster BEFORE the agent starts, or it crashloops on "cluster is not registered"
kubectl --context "$A" apply -f - >/dev/null <<EOK
apiVersion: admin.gloo.solo.io/v2
kind: KubernetesCluster
metadata: { name: ${A}, namespace: ${GLOO_MESH_NS} }
spec: { clusterDomain: cluster.local }
EOK
sed -e "s|LICENSE|$LIC|" -e "s|ADMIN_CIDR|$ADMIN_CIDR|" "$YAML_DIR/observability/gloo-mgmt-values.yaml" \
  | helm --kube-context "$A" upgrade -i gloo-platform gloo-platform/gloo-platform \
      -n "$GLOO_MESH_NS" --version "$GLOO_PLATFORM_VERSION" -f - >/dev/null
ok "installing (UI reachable from $ADMIN_CIDR only)"

step "[$A] wait for the three NLBs (mgmt server, telemetry gateway, UI)"
MGMT_HOST="$(wait_lb_host "$A" "$GLOO_MESH_NS" gloo-mesh-mgmt-server)" || die "no mgmt server LB"
TG_HOST="$(wait_lb_host "$A" "$GLOO_MESH_NS" gloo-telemetry-gateway)" || die "no telemetry gateway LB"
UI_HOST="$(wait_lb_host "$A" "$GLOO_MESH_NS" gloo-mesh-ui)" || die "no UI LB"
ok "mgmt  $MGMT_HOST (internal)"; ok "otel  $TG_HOST (internal)"; ok "ui    $UI_HOST"

step "[$A] register $B, copy the relay root cert + bootstrap token to $B"
kubectl --context "$A" apply -f "$YAML_DIR/observability/eks-b-cluster.yaml" >/dev/null
kubectl --context "$B" create namespace "$GLOO_MESH_NS" --dry-run=client -o yaml | kubectl --context "$B" apply -f - >/dev/null
for s in relay-root-tls-secret relay-identity-token-secret; do
  for _ in $(seq 1 30); do kubectl --context "$A" -n "$GLOO_MESH_NS" get secret "$s" >/dev/null 2>&1 && break; sleep 5; done
  kubectl --context "$A" -n "$GLOO_MESH_NS" get secret "$s" -o json \
    | jq 'del(.metadata.creationTimestamp,.metadata.resourceVersion,.metadata.uid,.metadata.ownerReferences,.metadata.managedFields)' \
    | kubectl --context "$B" apply -f - >/dev/null
done
ok "relay secrets copied"

step "[$B] Gloo agent + telemetry collector, relaying to $A over the VPC peering"
helm --kube-context "$B" upgrade -i gloo-platform-crds gloo-platform/gloo-platform-crds \
  -n "$GLOO_MESH_NS" --version "$GLOO_PLATFORM_VERSION" --wait --timeout 5m >/dev/null
sed -e "s|MGMT_HOST|$MGMT_HOST|" -e "s|TG_HOST|$TG_HOST|" "$YAML_DIR/observability/gloo-agent-values.yaml" \
  | helm --kube-context "$B" upgrade -i gloo-platform-agent gloo-platform/gloo-platform \
      -n "$GLOO_MESH_NS" --version "$GLOO_PLATFORM_VERSION" -f - >/dev/null
kubectl --context "$B" -n "$GLOO_MESH_NS" rollout status deploy/gloo-mesh-agent --timeout=300s >/dev/null
ok "[$B] agent connected"

step "[$A] UI"
kubectl --context "$A" -n "$GLOO_MESH_NS" rollout status deploy/gloo-mesh-ui --timeout=600s >/dev/null
UI_IP="$(resolve_first_ip "$UI_HOST")"
echo "  Gloo UI:  http://gloo-ui.${UI_IP}.sslip.io:8090   (also http://${UI_HOST}:8090)"
echo "  Look at:  Observability -> Graph (both clusters + the VM), Inventory -> Global Services, Security -> mTLS"
echo "$UI_IP" > "$STATE_DIR/gloo-ui-ip"

step "[$A] ztunnel metrics straight from Prometheus: connections by source and destination identity"
PROM="$(kubectl --context "$A" -n "$GLOO_MESH_NS" get pod -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}')"
kubectl --context "$A" -n "$GLOO_MESH_NS" exec "$PROM" -c prometheus-server -- sh -c \
  "wget -qO- 'http://localhost:9090/api/v1/query?query=sum(istio_tcp_connections_opened_total{destination_workload=\"catalog\",reporter=\"destination\"})%20by%20(source_cluster,source_principal,destination_cluster,connection_security_policy)'" \
  | python3 -c "import json,sys; [print('  ', r['metric'].get('connection_security_policy'), r['metric'].get('source_cluster'), r['metric'].get('source_principal'), '->', r['metric'].get('destination_cluster'), 'catalog', r['value'][1]) for r in json.load(sys.stdin)['data']['result']]" || true
