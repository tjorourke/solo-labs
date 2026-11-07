#!/usr/bin/env bash
# Optional shortcut for the explicit commands on the lab page. No teardown.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
CLUSTER="${CLUSTER:-hitl-sts-part2}"
[[ "$CLUSTER" == hitl-sts-part2* ]] || { echo 'Use a separate hitl-sts-part2* cluster'; exit 1; }
CTX="kind-$CLUSTER"
hitl_kubectl(){ command kubectl --context "$CTX" "$@"; }
set +x
set -a; . "${SECRETS_FILE:-$HOME/.solo/secrets.env}" >/dev/null 2>&1; set +a
[[ -n "${AGENTGATEWAY_LICENSE_KEY:-}" ]] || { echo 'AGENTGATEWAY_LICENSE_KEY missing'; exit 1; }
if ! kind get clusters | grep -qx "$CLUSTER"; then kind create cluster --name "$CLUSTER"; fi
hitl_kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/standard-install.yaml >/dev/null
R=oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts
helm --kube-context "$CTX" upgrade -i enterprise-agentgateway-crds "$R/enterprise-agentgateway-crds" -n agentgateway-system --create-namespace --version v2026.10.0 --wait >/dev/null
printf '%s' "$AGENTGATEWAY_LICENSE_KEY" | hitl_kubectl -n agentgateway-system create secret generic enterprise-agentgateway-license --from-file=enterprise-agentgateway-license-key=/dev/stdin --dry-run=client -o yaml | hitl_kubectl apply -f - >/dev/null
hitl_kubectl create ns keycloak --dry-run=client -o yaml | hitl_kubectl apply -f - >/dev/null
hitl_kubectl -n keycloak create configmap realm --from-file=realm.json=yaml-enterprise/realm.json --dry-run=client -o yaml | hitl_kubectl apply -f - >/dev/null
hitl_kubectl apply -f yaml-enterprise/keycloak.yaml >/dev/null
hitl_kubectl -n keycloak rollout status deploy/keycloak --timeout=300s
helm --kube-context "$CTX" upgrade -i enterprise-agentgateway "$R/enterprise-agentgateway" -n agentgateway-system --version v2026.10.0 -f yaml-enterprise/values.yaml --wait --timeout 6m >/dev/null
hitl_kubectl apply -f yaml/namespace.yaml
docker build -t users-mcp:dev src/users-mcp
kind load docker-image users-mcp:dev --name "$CLUSTER"
docker build -t hitl-extauth-sts-hitl-part2:dev src/hitl-extauth
kind load docker-image hitl-extauth-sts-hitl-part2:dev --name "$CLUSTER"
hitl_kubectl apply -f yaml/users-mcp/deployment.yaml
hitl_kubectl apply -f yaml/hitl/tool-policy.yaml
hitl_kubectl apply -f yaml-enterprise/extauth.yaml -f yaml-enterprise/dba-agent.yaml
hitl_kubectl apply -f yaml-enterprise/gateway.yaml -f yaml-enterprise/httproute.yaml -f yaml-enterprise/extauth-policy.yaml -f yaml-enterprise/extauth-timeout.yaml -f yaml-enterprise/sts-jwt.yaml
hitl_kubectl -n mcp-extauth-demo rollout status deploy/users-mcp --timeout=180s
hitl_kubectl -n mcp-extauth-demo rollout status deploy/hitl-extauth --timeout=180s
hitl_kubectl -n mcp-extauth-demo rollout status deploy/extauth-gw --timeout=900s
hitl_kubectl -n mcp-extauth-demo wait --for=condition=Ready pod/dba-agent --timeout=180s
echo "Enterprise STS ready in $CTX. Cluster left running."
