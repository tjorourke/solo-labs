#!/usr/bin/env bash
# 01-cluster.sh — kind cluster + Gateway API CRDs.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require kind; require kubectl; require helm; require openssl
check_docker

step "Creating kind cluster $CLUSTER_NAME"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  ok "cluster $CLUSTER_NAME already exists"
else
  # The kind config is generated so the OSS run gets its own cluster name and
  # host port, and both editions can be up at the same time.
  kind create cluster --config <(cat <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${CLUSTER_NAME}
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: ${GW_NODEPORT}
    hostPort: ${GW_NODEPORT}
    protocol: TCP
EOF
) >&2
  ok "cluster $CLUSTER_NAME created"
fi

step "Installing Gateway API CRDs $GATEWAY_API_VERSION"
# Version comes from versions.env (the repo matrix). The v1.5.x admission-policy
# problem is specific to the Solo Istio SMC bundled CRD install, not agentgateway.
kc apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" >/dev/null
ok "Gateway API $GATEWAY_API_VERSION installed"

step "Cluster ready"
echo "  Next: ./scripts/02-agentgateway.sh" >&2
