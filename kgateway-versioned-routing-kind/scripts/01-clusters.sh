#!/usr/bin/env bash
# 01-clusters.sh — create the three kind clusters (edge + two app clusters) and
# install the Gateway API CRDs on the edge cluster. Idempotent.

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
    ok "cluster '$name' already exists — skipping"
  else
    log "creating cluster '$name'..."
    kind create cluster --config "$config"
    ok "cluster '$name' created"
  fi
}

step "Creating kind clusters"
create_cluster "$EDGE_CLUSTER"       "$LAB_ROOT/kind/edge.yaml"
create_cluster "$APP_LATEST_CLUSTER" "$LAB_ROOT/kind/app-latest.yaml"
create_cluster "$APP_V2_CLUSTER"     "$LAB_ROOT/kind/app-v2.yaml"

step "Installing Gateway API CRDs ($GATEWAY_API_VERSION) on the edge cluster"
kctx "$EDGE_CTX" apply -f \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" \
  >/dev/null
ok "Gateway API CRDs applied to $EDGE_CTX"

step "Clusters ready"
echo "  edge:        $EDGE_CTX" >&2
echo "  app-latest:  $APP_LATEST_CTX" >&2
echo "  app-v2:      $APP_V2_CTX" >&2
echo "  Next:        ./scripts/02-kgateway.sh" >&2
