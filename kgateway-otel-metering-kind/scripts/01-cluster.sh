#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
step "Creating minimal kind cluster '${CLUSTER}'"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "cluster exists"
else
  kind create cluster --config "${ROOT}/kind/cluster.yaml"
fi
step "Installing Gateway API CRDs"
k apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml
