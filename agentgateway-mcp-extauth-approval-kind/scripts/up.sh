#!/usr/bin/env bash
# Bring up agentgateway + users-mcp + hitl-extauth on kind.
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

kubectl apply -f yaml/namespace.yaml

echo "Building and loading users-mcp:dev"
docker build -t users-mcp:dev src/users-mcp
kind load docker-image users-mcp:dev --name mcp-extauth-approval

echo "Building and loading hitl-extauth:dev"
docker build -t hitl-extauth:dev src/hitl-extauth
kind load docker-image hitl-extauth:dev --name mcp-extauth-approval

kubectl apply -f yaml/users-mcp/deployment.yaml
kubectl apply -f yaml/hitl/tool-policy.yaml
kubectl apply -f yaml/hitl/extauth.yaml
kubectl apply -f yaml/agentgateway/gateway.yaml
kubectl apply -f yaml/agentgateway/httproute.yaml
kubectl apply -f yaml/agentgateway/extauth-policy.yaml
kubectl apply -f yaml/agentgateway/extauth-timeout.yaml

kubectl -n mcp-extauth-demo rollout status deploy/users-mcp --timeout=180s
kubectl -n mcp-extauth-demo rollout status deploy/hitl-extauth --timeout=180s
kubectl -n mcp-extauth-demo rollout status deploy/extauth-gw --timeout=180s

echo
echo "agentgateway v${AGW_VERSION} (Gateway extauth-gw) is listening on http://localhost:30081/mcp"
echo "Admin API: kubectl -n mcp-extauth-demo port-forward svc/hitl-extauth-admin 8081:8081"
