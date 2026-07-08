#!/usr/bin/env bash
# deploy-workloads.sh — lay down the exercise workloads on the peered standup:
#   • Bookinfo on BOTH clusters (for the ingress + cross-cluster failover demos)
#   • catalog-mcp on east + orders-mcp on west (for the MCP federation demo)
#   • a dev-ui caller pod on east
# Idempotent. The platform standup (scripts/quick.sh) must already be green.
set -Eeuo pipefail
CLUSTER1="${CLUSTER1:-kind-east-ag}"
CLUSTER2="${CLUSTER2:-kind-west-ag}"
BOOK=https://raw.githubusercontent.com/istio/istio/release-1.24/samples/bookinfo/platform/kube

step() { printf '\n══> %s\n' "$*"; }

step "Bookinfo on both clusters (ambient + network label)"
for CTX in "$CLUSTER1" "$CLUSTER2"; do
  kubectl --context "$CTX" create ns bookinfo 2>/dev/null || true
  kubectl --context "$CTX" label ns bookinfo \
    istio.io/dataplane-mode=ambient \
    topology.istio.io/network="${CTX#kind-}" --overwrite >/dev/null
  kubectl --context "$CTX" -n bookinfo apply -f "$BOOK/bookinfo.yaml" >/dev/null
  kubectl --context "$CTX" -n bookinfo apply -f "$BOOK/bookinfo-versions.yaml" >/dev/null
  echo "   • [$CTX] bookinfo applied"
done

step "MCP tool servers — catalog on east, orders on west (global)"
mcp_server() {  # $1 ctx  $2 name  $3 extra-svc-labels
  kubectl --context "$1" -n ai-tools apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ServiceAccount
metadata: { name: $2 }
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: $2, labels: { app: $2 } }
spec:
  replicas: 1
  selector: { matchLabels: { app: $2 } }
  template:
    metadata: { labels: { app: $2 } }
    spec:
      serviceAccountName: $2
      containers:
      - name: mcp
        image: node:20-alpine
        command: ["npx","-y","@modelcontextprotocol/server-everything","sse"]
        ports: [{ containerPort: 3001 }]
---
apiVersion: v1
kind: Service
metadata:
  name: $2
  labels:
    app: $2
$3
spec:
  selector: { app: $2 }
  ports: [{ name: http, port: 3001, targetPort: 3001, appProtocol: http }]
EOF
}
for CTX in "$CLUSTER1" "$CLUSTER2"; do
  kubectl --context "$CTX" create ns ai-tools 2>/dev/null || true
  kubectl --context "$CTX" label ns ai-tools \
    istio.io/dataplane-mode=ambient \
    topology.istio.io/network="${CTX#kind-}" --overwrite >/dev/null
done
mcp_server "$CLUSTER1" catalog-mcp ""
mcp_server "$CLUSTER2" orders-mcp  "    solo.io/service-scope: global"

step "dev-ui caller on east"
kubectl --context "$CLUSTER1" create ns ai-agents 2>/dev/null || true
kubectl --context "$CLUSTER1" label ns ai-agents \
  istio.io/dataplane-mode=ambient \
  topology.istio.io/network="${CLUSTER1#kind-}" --overwrite >/dev/null
kubectl --context "$CLUSTER1" -n ai-agents apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata: { name: dev-ui }
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: dev-ui, labels: { app: dev-ui } }
spec:
  replicas: 1
  selector: { matchLabels: { app: dev-ui } }
  template:
    metadata: { labels: { app: dev-ui } }
    spec:
      serviceAccountName: dev-ui
      containers: [{ name: curl, image: curlimages/curl:8.5.0, command: ["sleep","infinity"] }]
EOF

step "Wait for everything Ready (first MCP pull can take ~90s)"
kubectl --context "$CLUSTER1" -n bookinfo  wait --for=condition=Ready pod -l app=productpage --timeout=240s >/dev/null
kubectl --context "$CLUSTER2" -n bookinfo  wait --for=condition=Ready pod -l app=productpage --timeout=240s >/dev/null
kubectl --context "$CLUSTER1" -n ai-tools  wait --for=condition=Ready pod --all --timeout=240s >/dev/null
kubectl --context "$CLUSTER2" -n ai-tools  wait --for=condition=Ready pod --all --timeout=240s >/dev/null
kubectl --context "$CLUSTER1" -n ai-agents wait --for=condition=Ready pod --all --timeout=120s >/dev/null
echo "   ✓ workloads ready on both clusters"
