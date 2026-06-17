#!/usr/bin/env bash
# quick.sh — one-shot orchestrator for the kgateway-versioned-routing-kind lab.
#
#   ./quick.sh up        — create clusters, install kgateway, deploy apps, wire routing
#   ./quick.sh demo      — run the routing scenarios
#   ./quick.sh teardown  — delete all three kind clusters
#   ./quick.sh status    — show key resources

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

cmd="${1:-up}"

case "$cmd" in
  up)
    load_secrets
    bash "$SCRIPT_DIR/01-clusters.sh"
    bash "$SCRIPT_DIR/02-kgateway.sh"
    bash "$SCRIPT_DIR/03-apps.sh"
    bash "$SCRIPT_DIR/04-routing.sh"
    cat >&2 <<EOF

══════════════════════════════════════════════════════════════════
  kgateway-versioned-routing-kind — UP
══════════════════════════════════════════════════════════════════
  edge gateway:  $EDGE_CTX        (kgateway-system)
  app-latest:    $APP_LATEST_CTX
  app-v2:        $APP_V2_CTX

  Run the routing demo:   ./scripts/quick.sh demo
  Tear everything down:   ./scripts/quick.sh teardown
EOF
    ;;

  demo)
    bash "$SCRIPT_DIR/demo.sh"
    ;;

  teardown)
    for c in "$EDGE_CLUSTER" "$APP_LATEST_CLUSTER" "$APP_V2_CLUSTER"; do
      step "Deleting kind cluster '$c'"
      if kind get clusters 2>/dev/null | grep -qx "$c"; then
        kind delete cluster --name "$c"
        ok "cluster '$c' deleted"
      else
        log "cluster '$c' not present — nothing to do"
      fi
    done
    ;;

  status)
    step "Edge gateway"
    kctx "$EDGE_CTX" -n "$GW_NS" get gateway,httproute,backend,enterprisekgatewaytrafficpolicy 2>/dev/null | sed 's/^/  /' >&2 || die "edge cluster not reachable"
    step "App clusters"
    echo "  app-latest:  $(kind_node_ip "$APP_LATEST_CLUSTER"):${APP_NODEPORT}" >&2
    kctx "$APP_LATEST_CTX" -n echo get deploy 2>/dev/null | sed 's/^/    /' >&2 || true
    echo "  app-v2:      $(kind_node_ip "$APP_V2_CLUSTER"):${APP_NODEPORT}" >&2
    kctx "$APP_V2_CTX" -n echo get deploy 2>/dev/null | sed 's/^/    /' >&2 || true
    ;;

  *)
    cat >&2 <<EOF
Usage:
  $0 up        — bring up the full lab (3 clusters)
  $0 demo      — run the routing scenarios
  $0 teardown  — delete all three kind clusters
  $0 status    — show key resources
EOF
    exit 2
    ;;
esac
