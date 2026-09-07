#!/usr/bin/env bash
# quick.sh — orchestrate the lab.
#   ./scripts/quick.sh up         # cluster, Gateway API, agentgateway, management UI, Keycloak, demo config
#   ./scripts/quick.sh status     # what is running
#   ./scripts/quick.sh teardown   # delete the kind cluster
#
# This lab is written as a read-along walkthrough in index.html; this driver runs
# the file-backed parts of it so labs-e2e.sh can prove the stack still stands up.
# The interactive checks in the page (port-forwards, the MCP inspector, the UI)
# are deliberately not here: they need a human or a browser.
#
# Versions come from versions.env, not the literals in the page, so the lab is
# exercised against the current product matrix.
set -Euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"

# shellcheck disable=SC1091
[ -f "$REPO_ROOT/versions.env" ] && source "$REPO_ROOT/versions.env"
[ -n "${SECRETS_FILE:-}" ] && [ -f "$SECRETS_FILE" ] && source "$SECRETS_FILE"

CLUSTER="${CLUSTER:-agw-quickstart}"
CTX="kind-${CLUSTER}"
AGW_VER="${AGW_CALVER_VERSION:-v2026.8.2}"
MGMT_VER="${SOLO_ENT_MGMT_VERSION:-0.5.6}"
GWAPI_VER="${GATEWAY_API_VERSION:-v1.5.1}"
AGW_NS=agentgateway-system

step() { printf '\n\033[1;36m══> %s\033[0m\n' "$*" >&2; }
k()    { kubectl --context "$CTX" "$@"; }

up() {
  : "${AGENTGATEWAY_LICENSE_KEY:?set AGENTGATEWAY_LICENSE_KEY (or point SECRETS_FILE at secrets-envs.sh)}"

  step "kind cluster '$CLUSTER'"
  kind get clusters 2>/dev/null | grep -qx "$CLUSTER" || kind create cluster --name "$CLUSTER"

  step "Gateway API CRDs ($GWAPI_VER)"
  k apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GWAPI_VER}/standard-install.yaml"

  step "agentgateway CRDs + control plane ($AGW_VER)"
  helm --kube-context "$CTX" upgrade -i --create-namespace -n "$AGW_NS" --version "$AGW_VER" \
    enterprise-agentgateway-crds \
    oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds
  helm --kube-context "$CTX" upgrade -i -n "$AGW_NS" --version "$AGW_VER" \
    enterprise-agentgateway \
    oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway \
    --set-string licensing.licenseKey="$AGENTGATEWAY_LICENSE_KEY"

  step "Solo Enterprise management UI ($MGMT_VER)"
  helm --kube-context "$CTX" upgrade -i management \
    oci://us-docker.pkg.dev/solo-public/solo-enterprise-helm/charts/management \
    -n "$AGW_NS" --create-namespace --version "$MGMT_VER" \
    --set cluster="mgmt-cluster" \
    --set products.agentgateway.enabled=true \
    --set "products.agentgateway.features.cost-management=true" \
    --set-string licensing.licenseKey="$AGENTGATEWAY_LICENSE_KEY"
  k -n "$AGW_NS" rollout status deploy/solo-enterprise-ui --timeout=600s

  step "Keycloak"
  k create namespace keycloak --dry-run=client -o yaml | k apply -f -
  k -n keycloak create configmap keycloak-realm-import \
    --from-file=realm.json="$ROOT/yaml/keycloak/realm.json" --dry-run=client -o yaml | k apply -f -
  k -n keycloak apply -f "$ROOT/yaml/keycloak/keycloak.yaml"
  k -n keycloak rollout status statefulset/keycloak --timeout=600s

  step "Gateway, MCP and authz"
  k create namespace demo --dry-run=client -o yaml | k apply -f -
  k apply -f "$ROOT/yaml/gateway/httpbin-route.yaml"
  k apply -f "$ROOT/yaml/mcp/mcp.yaml"
  k apply -f "$ROOT/yaml/mcp-code/backend.yaml"
  k apply -f "$ROOT/yaml/mcp-authz/policies.yaml"
  k -n demo rollout status deploy/agw --timeout=600s

  step "Observability"
  k apply -f "$ROOT/yaml/observability/tracing.yaml"

  step "Up. The LLM, guardrail and cost sections of the page need provider keys and are not run here."
}

case "${1:-up}" in
  up)       up ;;
  status)
    kind get clusters 2>/dev/null | sed 's/^/  /' >&2 || true
    k -n demo get gateway,httproute,enterpriseagentgatewaybackend 2>/dev/null | sed 's/^/  /' >&2 || true
    ;;
  teardown) kind delete cluster --name "$CLUSTER" ;;
  *) echo "usage: quick.sh [up|status|teardown]" >&2; exit 2 ;;
esac
