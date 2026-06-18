#!/usr/bin/env bash
# 01-cluster.sh — create the single kind cluster and install the Gateway API
# CRDs. Idempotent: reuses the cluster if it already exists.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib.sh"

require kind; require kubectl; require helm; check_docker

step "Ensuring kind cluster '$CLUSTER'"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  log "cluster '$CLUSTER' already exists — reusing"
else
  kind create cluster --config "$LAB_ROOT/kind/cluster.yaml" >/dev/null
  ok "cluster '$CLUSTER' created"
fi

step "Installing Gateway API CRDs ($GATEWAY_API_VERSION)"
kctx apply -f \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" >/dev/null
ok "Gateway API CRDs applied"
echo "  Next: ./scripts/02-agentgateway.sh" >&2
