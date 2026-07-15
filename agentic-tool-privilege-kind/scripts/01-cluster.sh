#!/usr/bin/env bash
# 01-cluster.sh — kind cluster + Gateway API CRDs. No MetalLB: every endpoint in
# this lab is reached by port-forward, so no external LoadBalancer IP is needed.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

step "Pre-flight"
require kind; require kubectl; require helm; require docker; require curl; require python3; require gcloud
check_docker; ok "tools + docker reachable"

step "Creating kind cluster '$CLUSTER_NAME'"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  ok "cluster '$CLUSTER_NAME' already exists — skipping"
else
  kind create cluster --config "$LAB_ROOT/kind/cluster.yaml"; ok "cluster created"
fi

step "Gateway API CRDs $GATEWAY_API_VERSION"
kc apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" >/dev/null
ok "Gateway API CRDs applied"

step "Cluster ready"; echo "  Next: ./scripts/02-keycloak.sh" >&2
