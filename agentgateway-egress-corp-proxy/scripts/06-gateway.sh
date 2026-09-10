#!/usr/bin/env bash
# 06-gateway.sh — the Gateway, the backends and the routes.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

step "Applying gateway parameters (Service overlay: NodePort ${GW_NODEPORT})"
kc apply --server-side -f "$SCRIPT_DIR/../$YAML_DIR/00-gateway-params.yaml" >/dev/null
ok "gateway parameters applied"

step "Creating the Gateway"
kc apply -f "$SCRIPT_DIR/../$YAML_DIR/30-gateway.yaml" >/dev/null
wait_deploy "$AGW_NS" "$GATEWAY_NAME"
ok "Gateway $GATEWAY_NAME programmed"

step "Applying backends and routes"
kc apply -f "$SCRIPT_DIR/../$YAML_DIR/40-backends.yaml" >/dev/null
kc apply -f "$SCRIPT_DIR/../$YAML_DIR/50-routes.yaml" >/dev/null
ok "backends and routes applied from $YAML_DIR/"

step "Gateway ready"
echo "  Test:  ./scripts/test.sh" >&2
echo "  URL:   ${GW_URL}/direct" >&2
