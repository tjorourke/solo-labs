#!/usr/bin/env bash
# 01-cluster.sh — create the kind cluster + Gateway API CRDs.
#
# No MetalLB: this lab exposes nothing via LoadBalancer; the kagent dashboard is
# reached by port-forward and the whole demo is driven from inside the cluster.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

step "Pre-flight"
require kind
require kubectl
require helm
require docker
check_docker
ok "tools + docker reachable"

step "Creating kind cluster '$CLUSTER_NAME'"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  ok "cluster '$CLUSTER_NAME' already exists — skipping"
else
  kind create cluster --config "$LAB_ROOT/kind/cluster.yaml"
  ok "cluster '$CLUSTER_NAME' created"
fi

step "Installing Gateway API CRDs $GATEWAY_API_VERSION"
kc apply -f \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" \
  >/dev/null
ok "Gateway API CRDs applied"

step "Cluster ready"
echo "  Context: $CTX" >&2
echo "  Next:    ./scripts/02-openshell.sh" >&2
