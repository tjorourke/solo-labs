#!/usr/bin/env bash
# Bring up agentgateway + users-mcp on kind.
set -euo pipefail
cd "$(dirname "$0")/.."

kind create cluster --config kind/kind-config.yaml

AGW_VERSION="${AGW_VERSION:-1.5.0}"
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.5.1}"

kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

helm upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
  --version "$AGW_VERSION" -n agentgateway-system --create-namespace
helm upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --version "$AGW_VERSION" -n agentgateway-system
kubectl -n agentgateway-system rollout status deploy/agentgateway --timeout=180s

kubectl create namespace mcp-write-approval
kubectl -n mcp-write-approval create configmap users-mcp-src --from-file=server.py=src/server.py
kubectl apply -f yaml/users-mcp.yaml
kubectl apply -f yaml/gateway.yaml
kubectl apply -f yaml/backend.yaml
kubectl apply -f yaml/route.yaml

kubectl -n mcp-write-approval rollout status deploy/users-mcp --timeout=180s
kubectl -n mcp-write-approval rollout status deploy/approval-gw --timeout=180s

echo
echo "agentgateway v${AGW_VERSION} (Gateway approval-gw) is listening on http://localhost:30080/mcp"
