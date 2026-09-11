#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER="${CLUSTER:-agw-virtual-keys}"
CTX="kind-${CLUSTER}"
NS=agentgateway-system
# Deliberate lab-local pin: the ConfigMap keyHash flow requires this tested API.
AGW_VERSION="${AGW_VERSION:-v2026.9.0}"
GWAPI_VERSION="${GWAPI_VERSION:-v1.5.1}"
MGMT_VERSION="${MGMT_VERSION:-0.5.7}"
REG=oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts
kc() { kubectl --context "$CTX" -n "$NS" "$@"; }
license() {
  if [[ -z "${AGENTGATEWAY_LICENSE_KEY:-}" ]]; then
    SECRETS_FILE="${SECRETS_FILE:-$HOME/code/solo/secrets/secrets-envs.sh}"
    if [[ -f "$SECRETS_FILE" ]]; then
      # shellcheck disable=SC1090
      source "$SECRETS_FILE"
    fi
  fi
  : "${AGENTGATEWAY_LICENSE_KEY:?Export AGENTGATEWAY_LICENSE_KEY or set SECRETS_FILE}"
  export AGENTGATEWAY_LICENSE_KEY
}

case "${1:-help}" in
  up)
    for tool in docker kind kubectl helm python3; do
      command -v "$tool" >/dev/null || { printf 'Missing prerequisite: %s\n' "$tool" >&2; exit 1; }
    done
    license
    if kind get clusters | python3 -c 'import sys; sys.exit(sys.argv[1] not in sys.stdin.read().splitlines())' "$CLUSTER"; then
      printf 'Using existing lab cluster %s\n' "$CLUSTER"
    else
      kind create cluster --name "$CLUSTER" --wait 120s
    fi
    kc apply --server-side -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GWAPI_VERSION}/experimental-install.yaml"
    helm upgrade --install agentgateway-crds "$REG/enterprise-agentgateway-crds" \
      --kube-context "$CTX" -n "$NS" --create-namespace --version "$AGW_VERSION" --wait --timeout 5m
    # Feed the license through stdin instead of including it in process arguments.
    export AGENTGATEWAY_LICENSE_KEY
    python3 -c 'import json,os; print(json.dumps({"licensing":{"licenseKey":os.environ["AGENTGATEWAY_LICENSE_KEY"]}}))' |
      helm upgrade --install enterprise-agentgateway "$REG/enterprise-agentgateway" \
        --kube-context "$CTX" -n "$NS" --version "$AGW_VERSION" \
        -f "$ROOT/yaml/values.yaml" -f - --wait --timeout 8m
    kc apply -f "$ROOT/yaml/virtual-keys.yaml" -f "$ROOT/yaml/model-catalog.yaml" \
      -f "$ROOT/yaml/mock.yaml" -f "$ROOT/yaml/gateway.yaml" \
      -f "$ROOT/yaml/auth-budget.yaml" -f "$ROOT/yaml/model-access.yaml" \
      -f "$ROOT/yaml/budgets.yaml"
    # The Python fixture reads server.py at process startup.
    kc rollout restart deployment/mock-llm
    kc rollout status deployment/mock-llm --timeout=180s
    kc wait gateway/virtual-keys --for=condition=Programmed --timeout=180s
    kc rollout status deployment/virtual-keys --timeout=180s
    printf '\nReady. Run bash scripts/quick.sh test or bash scripts/quick.sh forward\n'
    ;;
  test)
    export LAB_CONTEXT="$CTX"
    python3 "$ROOT/scripts/test.py"
    ;;
  demo)
    export LAB_CONTEXT="$CTX" LAB_SHOWCASE=1
    python3 "$ROOT/scripts/test.py"
    ;;
  models)
    export LAB_CONTEXT="$CTX" LAB_MODELS_ONLY=1
    python3 "$ROOT/scripts/test.py"
    ;;
  forward)
    kc port-forward service/virtual-keys "${PORT:-18080}:8080"
    ;;
  ui)
    license
    python3 -c 'import json,os; print(json.dumps({"licensing":{"licenseKey":os.environ["AGENTGATEWAY_LICENSE_KEY"]}}))' |
      helm upgrade --install management oci://us-docker.pkg.dev/solo-public/solo-enterprise-helm/charts/management \
        --kube-context "$CTX" -n "$NS" --version "$MGMT_VERSION" \
        -f "$ROOT/yaml/ui-values.yaml" --set cluster="$CLUSTER" -f - --wait --timeout 10m
    kc apply -f "$ROOT/yaml/telemetry.yaml"
    printf '\nUI installed. Run bash scripts/quick.sh ui-forward and open http://localhost:18090/age/\n'
    ;;
  ui-forward)
    kc port-forward service/solo-enterprise-ui "${UI_PORT:-18090}:80"
    ;;
  teardown)
    kind delete cluster --name "$CLUSTER"
    if kind get clusters | python3 -c 'import sys; sys.exit(sys.argv[1] not in sys.stdin.read().splitlines())' "$CLUSTER"; then
      printf 'Cluster still exists: %s\n' "$CLUSTER" >&2
      exit 1
    fi
    ;;
  *) printf 'Usage: bash scripts/quick.sh {up|test|demo|models|forward|ui|ui-forward|teardown}\n' ;;
esac
