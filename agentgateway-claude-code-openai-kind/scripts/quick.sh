#!/usr/bin/env bash
# quick.sh — orchestrate the lab.
#   ./scripts/quick.sh up         # 01 -> 04: cluster, agentgateway, backend, rbac
#   ./scripts/quick.sh demo       # port-forward to localhost:$PORT
#   ./scripts/quick.sh test       # run the three Anthropic-API scenarios
#   ./scripts/quick.sh status     # show cluster + gateway state
#   ./scripts/quick.sh teardown   # delete the kind cluster

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

cmd="${1:-up}"
case "$cmd" in
  up)
    "$SCRIPT_DIR/01-cluster.sh"
    "$SCRIPT_DIR/02-agentgateway.sh"
    "$SCRIPT_DIR/03-backend.sh"
    "$SCRIPT_DIR/04-rbac.sh"
    step "Up. Next: ./scripts/quick.sh demo   (then, in another shell) ./scripts/quick.sh test"
    ;;
  demo)    exec "$SCRIPT_DIR/demo.sh" ;;
  test)    exec "$SCRIPT_DIR/test.sh" ;;
  status)
    step "Cluster"
    kind get clusters 2>/dev/null | sed 's/^/  /' >&2 || true
    step "Gateway + routes + policy"
    kctx -n "$GW_NS" get gateway,httproute,agentgatewaybackend,enterpriseagentgatewaypolicy 2>/dev/null | sed 's/^/  /' >&2 || true
    ;;
  teardown)
    step "Deleting kind cluster '$CLUSTER'"
    kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
    ok "cluster deleted"
    ;;
  *) die "unknown command '$cmd' — use: up | demo | test | status | teardown" ;;
esac
