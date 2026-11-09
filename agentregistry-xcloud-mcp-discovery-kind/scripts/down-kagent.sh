#!/usr/bin/env bash
# Removes only the kagent step (step 9) from the running xcloud-mcp cluster, so it can be rebuilt with
# scripts/up-kagent.sh. Leaves the cluster, Keycloak, the registry and the /registry/* routes alone.
# Needs the Keycloak port-forward on 8180.
set -euo pipefail
set +x
cd "$(dirname "$0")/.."
source scripts/lib.sh
k() { kubectl --context "$CTX" "$@"; }
stop_kagent_port_forwards
k delete -f kagent/cloud-ops.yaml --ignore-not-found --wait=true >/dev/null 2>&1 || true
k delete -f yaml/agent-route.yaml --ignore-not-found >/dev/null
helm --kube-context "$CTX" uninstall management -n agentgateway-system --wait --timeout 5m >/dev/null 2>&1 || true
helm --kube-context "$CTX" uninstall kagent -n kagent --wait --timeout 5m >/dev/null 2>&1 || true
helm --kube-context "$CTX" uninstall kagent-crds -n kagent --wait --timeout 5m >/dev/null 2>&1 || true
k delete namespace kagent --ignore-not-found --wait=true --timeout=180s >/dev/null
k -n agentgateway-system delete secret kagent-backend-oidc kagent-management-license --ignore-not-found >/dev/null
# STS off again: back to the base gateway values.
helm --kube-context "$CTX" upgrade enterprise-agentgateway "$AGW_CHARTS/enterprise-agentgateway" --version "$AGW_VERSION" \
  -n agentgateway-system -f yaml/values.yaml --wait --timeout 6m >/dev/null
python3 kagent/keycloak-clients.py --remove
echo 'kagent step removed.'
