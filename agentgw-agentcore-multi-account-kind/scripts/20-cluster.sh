#!/usr/bin/env bash
# 20-cluster.sh — kind cluster + Gateway API CRDs. No local OCI registry: this
# lab never builds an image (agents deploy to AgentCore in source mode).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

step "Pre-flight"
require kind; require kubectl; require helm; require docker; require curl; require jq; require arctl; require aws; require tofu
check_docker; ok "tools + docker reachable"

step "Creating kind cluster '$CLUSTER_NAME'"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  # Reuse only a cluster with the host :80 -> ingress NodePort mapping.
  if docker port "${CLUSTER_NAME}-control-plane" 30080 2>/dev/null | grep -q ':80$'; then
    ok "cluster '$CLUSTER_NAME' already exists with the :80 ingress mapping — reusing"
  else
    warn "cluster '$CLUSTER_NAME' exists without the :80 mapping — recreating from kind/cluster.yaml"
    kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 || true
    kind create cluster --name "$CLUSTER_NAME" --config "$LAB_ROOT/kind/cluster.yaml"; ok "cluster recreated"
  fi
else
  kind create cluster --name "$CLUSTER_NAME" --config "$LAB_ROOT/kind/cluster.yaml"; ok "cluster created"
fi

step "Gateway API CRDs $GATEWAY_API_VERSION"
kc apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" >/dev/null
ok "Gateway API CRDs applied"

step "Cluster ready"; echo "  Next: ./scripts/21-keycloak.sh" >&2
