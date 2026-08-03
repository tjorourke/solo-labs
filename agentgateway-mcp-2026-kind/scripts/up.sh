#!/usr/bin/env bash
# Fast-path bring-up for the MCP 2026-07-28 wire lab.
# The lab page shows every command individually; this script just runs them in order.
set -euo pipefail
cd "$(dirname "$0")/.."

kind create cluster --config kind/kind-config.yaml

kind load docker-image ghcr.io/agentgateway/agentgateway:v1.4.1 --name mcp-2026 2>/dev/null || true

kubectl create namespace mcp-2026
kubectl -n mcp-2026 create configmap ops-mcp-src --from-file=server.py=src/server.py
kubectl apply -f yaml/ops-mcp.yaml
kubectl apply -f yaml/agentgateway.yaml

kubectl -n mcp-2026 rollout status deploy/ops-mcp --timeout=180s
kubectl -n mcp-2026 rollout status deploy/agentgateway --timeout=180s

echo
echo "agentgateway v1.4.1 is listening on http://localhost:30080/mcp"
