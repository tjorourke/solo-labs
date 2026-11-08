#!/usr/bin/env bash
set -euo pipefail
set +x
cd "$(dirname "$0")/.."
source "${SECRETS_FILE:-$HOME/.solo/secrets.env}"
: "${OPENAI_API_KEY:?Set OPENAI_API_KEY in the secrets file}"
: "${AGENTGATEWAY_LICENSE_KEY:?Set AGENTGATEWAY_LICENSE_KEY in the secrets file}"
if kind get clusters | rg -qx openai-decisions; then
  echo 'Cluster openai-decisions already exists. Refusing to replace it.' >&2
  exit 1
fi
kind create cluster --config kind/cluster.yaml
CTX=kind-openai-decisions
R=oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts
kubectl --context "$CTX" apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/standard-install.yaml
helm --kube-context "$CTX" upgrade -i enterprise-agentgateway-crds "$R/enterprise-agentgateway-crds" --version v2026.10.2 -n agentgateway-system --create-namespace --wait
printf '%s' "$AGENTGATEWAY_LICENSE_KEY" | kubectl --context "$CTX" -n agentgateway-system create secret generic enterprise-agentgateway-license --from-file=enterprise-agentgateway-license-key=/dev/stdin --dry-run=client -o yaml | kubectl --context "$CTX" apply -f -
printf 'Bearer %s' "$OPENAI_API_KEY" | kubectl --context "$CTX" -n agentgateway-system create secret generic openai-secret --from-file=Authorization=/dev/stdin --dry-run=client -o yaml | kubectl --context "$CTX" apply -f -
helm --kube-context "$CTX" upgrade -i enterprise-agentgateway "$R/enterprise-agentgateway" --version v2026.10.2 -n agentgateway-system -f yaml/values.yaml --wait --timeout 6m
kubectl --context "$CTX" apply --dry-run=server -f yaml/gateway.yaml -f yaml/backend.yaml -f yaml/httproute.yaml
kubectl --context "$CTX" apply -f yaml/gateway.yaml -f yaml/backend.yaml -f yaml/httproute.yaml
kubectl --context "$CTX" -n agentgateway-system wait --for=condition=Programmed gateway/agentgateway-proxy --timeout=180s
kubectl --context "$CTX" -n agentgateway-system wait --for=create deployment/agentgateway-proxy --timeout=180s
kubectl --context "$CTX" -n agentgateway-system rollout status deployment/agentgateway-proxy --timeout=360s
echo 'Up. The cluster stays running. Run ./scripts/quick.sh test.'
