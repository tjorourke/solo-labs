#!/usr/bin/env bash
# quick.sh — orchestrator for the agentgateway-versioned-routing-kind lab.
#
#   ./quick.sh up               — ensure clusters, install agentgateway, deploy apps, wire routing
#   ./quick.sh demo             — run the routing scenarios
#   ./quick.sh teardown         — remove the agentgateway install + routing (KEEPS the clusters)
#   ./quick.sh teardown-clusters— delete all three kind clusters (also removes part 1)
#   ./quick.sh status           — show key resources

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

cmd="${1:-up}"

case "$cmd" in
  up)
    load_secrets
    bash "$SCRIPT_DIR/01-clusters.sh"
    bash "$SCRIPT_DIR/02-agentgateway.sh"
    bash "$SCRIPT_DIR/03-apps.sh"
    bash "$SCRIPT_DIR/04-routing.sh"
    cat >&2 <<EOF

══════════════════════════════════════════════════════════════════
  agentgateway-versioned-routing-kind — UP
══════════════════════════════════════════════════════════════════
  edge gateway:  $EDGE_CTX        (agentgateway-system)
  app-latest:    $APP_LATEST_CTX
  app-v2:        $APP_V2_CTX

  Run the routing demo:   ./scripts/quick.sh demo
  Remove AGW (keep clusters): ./scripts/quick.sh teardown
EOF
    ;;

  demo)
    bash "$SCRIPT_DIR/demo.sh"
    ;;

  teardown)
    step "Removing agentgateway routing + install from $EDGE_CTX (clusters kept)"
    kctx "$EDGE_CTX" -n "$GW_NS" delete httproute versioned-routing --ignore-not-found >/dev/null 2>&1 || true
    kctx "$EDGE_CTX" -n "$GW_NS" delete enterpriseagentgatewaypolicy jwt-version --ignore-not-found >/dev/null 2>&1 || true
    kctx "$EDGE_CTX" -n "$GW_NS" delete agentgatewaybackend app-latest app-v2 --ignore-not-found >/dev/null 2>&1 || true
    kctx "$EDGE_CTX" -n "$GW_NS" delete gateway "$GW_NAME" --ignore-not-found >/dev/null 2>&1 || true
    helm --kube-context "$EDGE_CTX" uninstall enterprise-agentgateway -n "$GW_NS" >/dev/null 2>&1 || true
    helm --kube-context "$EDGE_CTX" uninstall enterprise-agentgateway-crds -n "$GW_NS" >/dev/null 2>&1 || true
    kctx "$EDGE_CTX" delete namespace "$GW_NS" --ignore-not-found >/dev/null 2>&1 || true
    ok "agentgateway removed; kgw-edge, app-latest and app-v2 still running"
    ;;

  teardown-clusters)
    for c in "$EDGE_CLUSTER" "$APP_LATEST_CLUSTER" "$APP_V2_CLUSTER"; do
      step "Deleting kind cluster '$c'"
      if kind get clusters 2>/dev/null | grep -qx "$c"; then
        kind delete cluster --name "$c"; ok "cluster '$c' deleted"
      else
        log "cluster '$c' not present"
      fi
    done
    ;;

  status)
    step "agentgateway edge"
    kctx "$EDGE_CTX" -n "$GW_NS" get gateway,httproute,agentgatewaybackend,enterpriseagentgatewaypolicy 2>/dev/null | sed 's/^/  /' >&2 || die "edge cluster not reachable"
    step "App clusters"
    echo "  app-latest:  $(kind_node_ip "$APP_LATEST_CLUSTER"):${APP_NODEPORT}" >&2
    echo "  app-v2:      $(kind_node_ip "$APP_V2_CLUSTER"):${APP_NODEPORT}" >&2
    ;;

  *)
    cat >&2 <<EOF
Usage:
  $0 up                — bring up agentgateway on the shared clusters
  $0 demo              — run the routing scenarios
  $0 teardown          — remove agentgateway, keep the clusters
  $0 teardown-clusters — delete all three kind clusters
  $0 status            — show key resources
EOF
    exit 2
    ;;
esac
