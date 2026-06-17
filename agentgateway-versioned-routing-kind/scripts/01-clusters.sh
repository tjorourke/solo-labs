#!/usr/bin/env bash
# 01-clusters.sh — ensure the three kind clusters exist (edge + two app
# clusters) and the Gateway API CRDs are on the edge. Idempotent, so if part 1
# (kgateway-versioned-routing-kind) already created these clusters this just
# reuses them.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

step "Pre-flight"
require kind; require kubectl; require helm; require docker
check_docker
ok "tools + docker reachable"

create_cluster() {
  local name="$1" config="$2"
  if kind get clusters 2>/dev/null | grep -qx "$name"; then
    ok "cluster '$name' already exists — reusing"
  else
    log "creating cluster '$name'..."
    kind create cluster --config "$config"
    ok "cluster '$name' created"
  fi
}

step "Ensuring kind clusters"
create_cluster "$EDGE_CLUSTER"       "$LAB_ROOT/kind/edge.yaml"
create_cluster "$APP_LATEST_CLUSTER" "$LAB_ROOT/kind/app-latest.yaml"
create_cluster "$APP_V2_CLUSTER"     "$LAB_ROOT/kind/app-v2.yaml"

step "Ensuring Gateway API CRDs ($GATEWAY_API_VERSION) on the edge cluster"
kctx "$EDGE_CTX" apply -f \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" \
  >/dev/null
ok "Gateway API CRDs present on $EDGE_CTX"

echo "  Next: ./scripts/02-agentgateway.sh" >&2
