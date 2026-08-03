#!/usr/bin/env bash
# Fast-path bring-up for the MCP 2026-07-28 wire lab.
# The lab page shows every command individually; this script just runs them in order.
set -euo pipefail
cd "$(dirname "$0")/.."

kind create cluster --config kind/kind-config.yaml

# Gateway API CRDs (standard channel)
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/standard-install.yaml

# agentgateway control plane, pinned to v1.4.1
helm upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
  --version 1.4.1 -n agentgateway-system --create-namespace
helm upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --version 1.4.1 -n agentgateway-system
kubectl -n agentgateway-system rollout status deploy/agentgateway --timeout=180s

kubectl create namespace mcp-2026
kubectl -n mcp-2026 create configmap ops-mcp-src --from-file=server.py=src/server.py
kubectl apply -f yaml/ops-mcp.yaml
kubectl apply -f yaml/gateway.yaml
kubectl apply -f yaml/backend-route.yaml

kubectl -n mcp-2026 rollout status deploy/ops-mcp --timeout=180s
kubectl -n mcp-2026 rollout status deploy/mcp-gw --timeout=180s

echo
echo "agentgateway v1.4.1 (Gateway mcp-gw) is listening on http://localhost:30080/mcp"
