#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# EDITION=oss runs the virtual-keys flow only (yaml-oss/) on OSS agentgateway, in
# its own cluster. The provider-key flow needs EnterpriseAgentgatewayExternalSecret.
EDITION="${EDITION:-enterprise}"
case "$EDITION" in
  enterprise) CLUSTER="${CLUSTER:-agw-vault-secrets}"; YAML="$ROOT/yaml" ;;
  oss) CLUSTER="${CLUSTER:-agw-vault-secrets-oss}"; YAML="$ROOT/yaml-oss" ;;
  *) printf 'EDITION must be enterprise or oss\n' >&2; exit 1 ;;
esac
CTX="kind-${CLUSTER}"
NS=agentgateway-system
AGW_VERSION="${AGW_VERSION:-v2026.9.0}"
OSS_VERSION="${OSS_VERSION:-v1.5.0}"
GWAPI_VERSION="${GWAPI_VERSION:-v1.5.1}"
MGMT_VERSION="${MGMT_VERSION:-0.5.7}"
VAULT_CHART_VERSION="${VAULT_CHART_VERSION:-0.34.1}"
CSI_DRIVER_VERSION="${CSI_DRIVER_VERSION:-1.6.1}"
ESO_VERSION="${ESO_VERSION:-2.11.0}"
REG=oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts
OSS_REG=oci://cr.agentgateway.dev/charts
kc() { kubectl --context "$CTX" -n "$NS" "$@"; }
vault_exec() { kubectl --context "$CTX" -n vault exec vault-0 -- "$@"; }
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
    [[ "$EDITION" == enterprise ]] && license
    if kind get clusters | python3 -c 'import sys; sys.exit(sys.argv[1] not in sys.stdin.read().splitlines())' "$CLUSTER"; then
      printf 'Using existing lab cluster %s\n' "$CLUSTER"
    else
      kind create cluster --name "$CLUSTER" --wait 120s
    fi
    kubectl --context "$CTX" apply --server-side -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GWAPI_VERSION}/experimental-install.yaml"

    # --- HashiCorp Vault, dev-mode (disposable, in-memory). csi.enabled=true
    # brings up the vault-csi-provider daemonset from the same chart.
    helm repo add hashicorp https://helm.releases.hashicorp.com >/dev/null 2>&1 || true
    helm repo update hashicorp >/dev/null
    helm upgrade --install vault hashicorp/vault --kube-context "$CTX" \
      -n vault --create-namespace --version "$VAULT_CHART_VERSION" \
      --set "server.dev.enabled=true" --set "server.dev.devRootToken=root" \
      --set "injector.enabled=false" --set "csi.enabled=$([[ "$EDITION" == enterprise ]] && echo true || echo false)" \
      --wait --timeout 5m
    # vault's StatefulSet uses the chart's default OnDelete update strategy, so
    # "rollout status" fails on it outright ("only available for RollingUpdate
    # strategy type") -- wait on pod readiness instead.
    kubectl --context "$CTX" -n vault wait pod/vault-0 --for=condition=Ready --timeout=180s

    if [[ "$EDITION" == enterprise ]]; then
      kubectl --context "$CTX" -n vault rollout status daemonset/vault-csi-provider --timeout=180s
      # --- Secrets Store CSI Driver. Rotation is off by default in the chart;
      # without enableSecretRotation the CSI-mounted file never refreshes after
      # pod start, so the provider-key rotation demo needs it explicitly on.
      helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts >/dev/null 2>&1 || true
      helm repo update secrets-store-csi-driver >/dev/null
      helm upgrade --install csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver \
        --kube-context "$CTX" -n csi-secrets-store --create-namespace --version "$CSI_DRIVER_VERSION" \
        --set "enableSecretRotation=true" --set "rotationPollInterval=15s" \
        --wait --timeout 5m
      kubectl --context "$CTX" -n csi-secrets-store rollout status daemonset/csi-secrets-store-secrets-store-csi-driver --timeout=180s
    fi

    # --- External Secrets Operator.
    helm repo add external-secrets https://charts.external-secrets.io >/dev/null 2>&1 || true
    helm repo update external-secrets >/dev/null
    helm upgrade --install external-secrets external-secrets/external-secrets \
      --kube-context "$CTX" -n external-secrets --create-namespace --version "$ESO_VERSION" \
      --wait --timeout 5m

    kc create namespace "$NS" --dry-run=client -o yaml | kubectl --context "$CTX" apply -f -

    # --- Vault bootstrap: KV v2 writes, Kubernetes auth, two least-privilege
    # roles/policies. secret/ is auto-mounted as KV v2 in dev-mode, so every
    # path below is secret/data/<path>, not secret/<path>.
    vault_exec vault kv put secret/openai-api-key api-key=sk-vault-demo-openai-key-v1
    python3 "$ROOT/scripts/seed-virtual-keys.py" | while IFS= read -r line; do
      eval "vault_exec $line"
    done
    vault_exec vault auth enable kubernetes 2>/dev/null || true
    K8S_HOST="https://kubernetes.default.svc"
    vault_exec sh -c "vault write auth/kubernetes/config kubernetes_host=${K8S_HOST}"
    vault_exec sh -c 'vault policy write openai - <<EOF
path "secret/data/openai-api-key" {
  capabilities = ["read"]
}
EOF'
    if [[ "$EDITION" == enterprise ]]; then
      vault_exec vault write auth/kubernetes/role/agentgateway \
        bound_service_account_names=enterprise-agentgateway \
        bound_service_account_namespaces="$NS" \
        policies=openai ttl=1h
    fi
    vault_exec sh -c 'vault policy write virtual-keys - <<EOF
path "secret/data/virtual-keys/*" {
  capabilities = ["read"]
}
EOF'
    vault_exec vault write auth/kubernetes/role/eso-virtual-keys \
      bound_service_account_names=eso-virtual-keys-reader \
      bound_service_account_namespaces="$NS" \
      policies=virtual-keys ttl=1h

    kc apply -f "$YAML/eso-secretstore.yaml"

    if [[ "$EDITION" == oss ]]; then
      helm upgrade --install agentgateway-crds "$OSS_REG/agentgateway-crds" \
        --kube-context "$CTX" -n "$NS" --version "$OSS_VERSION" --wait --timeout 5m
      helm upgrade --install agentgateway "$OSS_REG/agentgateway" \
        --kube-context "$CTX" -n "$NS" --version "$OSS_VERSION" --wait --timeout 5m
      kc apply -f "$YAML/mock.yaml" -f "$YAML/eso-external-secret.yaml" \
        -f "$YAML/gateway.yaml" -f "$YAML/virtual-keys-policy.yaml"
      kc rollout restart deployment/mock-llm
      kc rollout status deployment/mock-llm --timeout=180s
      kc wait gateway/vault-secrets --for=condition=Programmed --timeout=180s
      kc rollout status deployment/vault-secrets --timeout=180s
      printf '\nReady (OSS, virtual keys only). Run EDITION=oss bash scripts/quick.sh test\n'
      exit 0
    fi

    kc apply -f "$ROOT/yaml/secret-provider-class.yaml"
    # Feed the license through stdin instead of including it in process arguments.
    export AGENTGATEWAY_LICENSE_KEY
    helm upgrade --install agentgateway-crds "$REG/enterprise-agentgateway-crds" \
      --kube-context "$CTX" -n "$NS" --create-namespace --version "$AGW_VERSION" --wait --timeout 5m
    python3 -c 'import json,os; print(json.dumps({"licensing":{"licenseKey":os.environ["AGENTGATEWAY_LICENSE_KEY"]}}))' |
      helm upgrade --install enterprise-agentgateway "$REG/enterprise-agentgateway" \
        --kube-context "$CTX" -n "$NS" --version "$AGW_VERSION" \
        -f "$ROOT/yaml/csi-store-values.yaml" -f - --wait --timeout 8m

    kc apply -f "$ROOT/yaml/mock.yaml" -f "$ROOT/yaml/external-secret.yaml" \
      -f "$ROOT/yaml/eso-external-secret.yaml" -f "$ROOT/yaml/backend-openai.yaml" \
      -f "$ROOT/yaml/gateway.yaml" -f "$ROOT/yaml/virtual-keys-policy.yaml"
    kc rollout restart deployment/mock-llm
    kc rollout status deployment/mock-llm --timeout=180s
    kc wait gateway/vault-secrets --for=condition=Programmed --timeout=180s
    kc rollout status deployment/vault-secrets --timeout=180s
    printf '\nReady. Run bash scripts/quick.sh test or bash scripts/quick.sh rotate\n'
    ;;
  test)
    export LAB_CONTEXT="$CTX" LAB_EDITION="$EDITION"
    python3 "$ROOT/scripts/test.py"
    ;;
  demo)
    export LAB_CONTEXT="$CTX" LAB_EDITION="$EDITION" LAB_SHOWCASE=1
    python3 "$ROOT/scripts/test.py"
    ;;
  rotate)
    [[ "$EDITION" == enterprise ]] || { printf 'rotate needs the Enterprise provider-key flow\n' >&2; exit 1; }
    export LAB_CONTEXT="$CTX"
    python3 "$ROOT/scripts/rotate.py"
    ;;
  forward)
    kc port-forward service/vault-secrets "${PORT:-18080}:8080"
    ;;
  ui)
    [[ "$EDITION" == enterprise ]] || { printf 'The optional UI is part of the Enterprise run\n' >&2; exit 1; }
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
  *) printf 'Usage: bash scripts/quick.sh {up|test|demo|rotate|forward|ui|ui-forward|teardown}\n' ;;
esac
