#!/usr/bin/env bash
# 01-cluster.sh — kind cluster + a host-side local OCI registry on :5001 + Gateway
# API CRDs. The local registry is what `arctl build --push` pushes to and what the
# kagent pods pull from (the scaffolds default to localhost:5001/...).
# Registry wiring follows the canonical kind recipe:
# https://kind.sigs.k8s.io/docs/user/local-registry/

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

step "Pre-flight"
require kind; require kubectl; require helm; require docker; require curl; require jq; require arctl
check_docker; ok "tools + docker reachable"

step "Local registry container '$REG_NAME' on :$REG_PORT"
if [[ "$(docker inspect -f '{{.State.Running}}' "$REG_NAME" 2>/dev/null)" == "true" ]]; then
  ok "registry '$REG_NAME' already running"
else
  docker run -d --restart=always -p "127.0.0.1:${REG_PORT}:5000" --name "$REG_NAME" registry:2 >/dev/null
  ok "registry '$REG_NAME' started"
fi

step "Creating kind cluster '$CLUSTER_NAME'"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  # Only reuse a cluster that was created from kind/cluster.yaml — i.e. one that
  # publishes host :80 -> the ingress NodePort. A cluster of the same name created
  # some other way (e.g. a bare `kind create cluster --name agentcore-demo`) has no
  # :80 mapping, so every *.localtest.me console would be unreachable and arctl login
  # would fail. Detect that and recreate, so the lab works every time.
  if docker port "${CLUSTER_NAME}-control-plane" 2>/dev/null | grep -q '^80/tcp'; then
    ok "cluster '$CLUSTER_NAME' already exists with the :80 ingress mapping — reusing"
  else
    warn "cluster '$CLUSTER_NAME' exists but is missing the host :80 -> ingress mapping — recreating from kind/cluster.yaml"
    kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 || true
    kind create cluster --name "$CLUSTER_NAME" --config "$LAB_ROOT/kind/cluster.yaml"; ok "cluster recreated"
  fi
else
  kind create cluster --name "$CLUSTER_NAME" --config "$LAB_ROOT/kind/cluster.yaml"; ok "cluster created"
fi

step "Wiring nodes to the local registry"
# Per-node hosts.toml so containerd resolves localhost:5001 -> kind-registry:5000.
REGISTRY_DIR="/etc/containerd/certs.d/localhost:${REG_PORT}"
for node in $(kind get nodes --name "$CLUSTER_NAME"); do
  docker exec "$node" mkdir -p "$REGISTRY_DIR"
  cat <<EOF | docker exec -i "$node" cp /dev/stdin "$REGISTRY_DIR/hosts.toml"
[host."http://${REG_NAME}:5000"]
EOF
done
# Join the registry to the kind docker network so the nodes can reach it by name.
if [[ "$(docker inspect -f '{{json .NetworkSettings.Networks.kind}}' "$REG_NAME" 2>/dev/null)" == "null" ]]; then
  docker network connect kind "$REG_NAME" >/dev/null 2>&1 || true
fi
ok "nodes point localhost:${REG_PORT} -> ${REG_NAME}:5000"

step "Advertising the registry to the cluster (local-registry-hosting ConfigMap)"
kc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${REG_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF
ok "local-registry-hosting applied"

step "Gateway API CRDs $GATEWAY_API_VERSION"
kc apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" >/dev/null
ok "Gateway API CRDs applied"

step "Cluster ready"; echo "  Next: ./scripts/02-kagent.sh" >&2
