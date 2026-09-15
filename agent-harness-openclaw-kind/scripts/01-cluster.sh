#!/usr/bin/env bash
# 01-cluster.sh — create the kind cluster on the pinned node image.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
require kind; require kubectl; require helm; check_docker

step "kind cluster ${CLUSTER_NAME} (${KIND_NODE_IMAGE})"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  log "cluster exists; reusing"
else
  kind create cluster --name "$CLUSTER_NAME" --image "$KIND_NODE_IMAGE" \
    --config "$LAB_DIR/kind/cluster.yaml" --wait 180s
fi
kc wait nodes --all --for=condition=Ready --timeout=180s >/dev/null
kc get nodes
ok "cluster ready (context ${CTX})"
