#!/usr/bin/env bash
# 01-cluster.sh — create the kind cluster and install the CRDs the lab needs:
# upstream Gateway API, and the Gateway API Inference Extension (GIE) bundle
# (InferencePool + friends). Idempotent.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

require kind; require kubectl; require helm; check_docker

step "Creating kind cluster '$CLUSTER_NAME'"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  ok "cluster '$CLUSTER_NAME' already exists"
else
  kind create cluster --config "$LAB_ROOT/kind/inference.yaml" >/dev/null
  ok "cluster '$CLUSTER_NAME' created"
fi
kc wait --for=condition=Ready nodes --all --timeout=120s >/dev/null

step "Installing Gateway API CRDs $GATEWAY_API_VERSION"
kc apply --server-side -f \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" >/dev/null
ok "Gateway API CRDs installed"

step "Installing Gateway API Inference Extension CRDs $GIE_VERSION"
kc apply -f "$GIE_MANIFESTS" >/dev/null
ok "GIE CRDs installed (InferencePool served as $(kc get crd inferencepools.inference.networking.k8s.io -o jsonpath='{.spec.versions[*].name}' 2>/dev/null))"
