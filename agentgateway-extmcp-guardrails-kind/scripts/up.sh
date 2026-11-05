#!/usr/bin/env bash
# Fast-path bring-up for the ExtMCP guardrails lab.
# The lab page shows every command individually; this script just runs them in order.
set -euo pipefail
cd "$(dirname "$0")/.."

kind create cluster --config kind/kind-config.yaml

AGW_VERSION="${AGW_VERSION:-1.5.0}"
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.5.1}"

# Gateway API CRDs (standard channel)
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

# agentgateway control plane (OSS)
helm upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
  --version "$AGW_VERSION" -n agentgateway-system --create-namespace
helm upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --version "$AGW_VERSION" -n agentgateway-system
kubectl -n agentgateway-system rollout status deploy/agentgateway --timeout=180s

# Build and load the ExtMCP guardrail policy server image.
docker build -t guardrail-mcp:lab -f src/Dockerfile.policy src
kind load docker-image guardrail-mcp:lab --name extmcp-guardrails

kubectl apply -f yaml/gateway.yaml
kubectl -n extmcp-demo create configmap crm-mcp-src --from-file=server.py=src/server.py \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f yaml/crm-mcp.yaml
kubectl apply -f yaml/guardrail-server.yaml
kubectl apply -f yaml/guardrail-policy.yaml

kubectl -n extmcp-demo rollout status deploy/crm-mcp --timeout=180s
kubectl -n extmcp-demo rollout status deploy/guardrail-mcp --timeout=180s
kubectl -n extmcp-demo rollout status deploy/extmcp-gw --timeout=180s

echo
echo "Up. Reach the gateway with:"
echo "  kubectl -n extmcp-demo port-forward svc/extmcp-gw 8080:3000 &"
echo "  npx -y @modelcontextprotocol/inspector@0.21.2 --cli http://localhost:8080/mcp --transport http --method tools/list"
