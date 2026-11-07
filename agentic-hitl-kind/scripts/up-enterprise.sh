#!/usr/bin/env bash
# Optional shortcut for the explicit commands on the lab page. No teardown.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
CLUSTER="${CLUSTER:-hitl-sts-part1}"
[[ "$CLUSTER" == hitl-sts-part1* ]] || { echo 'Use a separate hitl-sts-part1* cluster'; exit 1; }
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
hitl_kubectl apply -f yaml/namespaces/00-namespaces.yaml
docker build -t ops-tools:dev src/ops-tools
kind load docker-image ops-tools:dev --name "$CLUSTER"
docker build -t hitl-extauth-sts-hitl-part1:dev src/hitl-extauth
kind load docker-image hitl-extauth-sts-hitl-part1:dev --name "$CLUSTER"
hitl_kubectl apply -f yaml/ops-tools/deployment.yaml

hitl_kubectl apply -f yaml-enterprise/extauth.yaml -f yaml-enterprise/dba-agent.yaml
hitl_kubectl apply -f yaml-enterprise/gateway.yaml -f yaml-enterprise/httproutes.yaml -f yaml-enterprise/extauth-policy.yaml -f yaml-enterprise/extauth-timeout.yaml -f yaml-enterprise/sts-jwt.yaml
hitl_kubectl -n ops-tools rollout status deploy/ops-tools --timeout=180s
hitl_kubectl -n hitl rollout status deploy/hitl-extauth --timeout=180s
hitl_kubectl -n agentgateway-system rollout status deploy/hitl-gateway --timeout=900s
hitl_kubectl -n ops-tools wait --for=condition=Ready pod/dba-agent --timeout=180s
echo "Enterprise STS ready in $CTX. Cluster left running."
