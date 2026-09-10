#!/usr/bin/env bash
# quick.sh — the harness entry point: up | test | teardown | status.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() { echo "usage: $0 {up|test|teardown|status}" >&2; exit 2; }

case "${1:-}" in
  up)
    require_secrets
    "$SCRIPT_DIR/01-cluster.sh"
    "$SCRIPT_DIR/02-agentgateway.sh"
    "$SCRIPT_DIR/03-pki.sh"
    "$SCRIPT_DIR/04-upstream.sh"
    "$SCRIPT_DIR/05-proxies.sh"
    "$SCRIPT_DIR/06-gateway.sh"
    ;;
  test)
    "$SCRIPT_DIR/test.sh"
    ;;
  teardown)
    step "Deleting kind cluster $CLUSTER_NAME"
    kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 || true
    # Regenerate the PKI next time rather than reusing keys from a dead cluster.
    rm -rf "$PKI_DIR"
    ok "cluster and generated PKI removed"
    ;;
  status)
    kc get pods -A 2>/dev/null | grep -E 'agentgateway|egress|upstream' || true
    kc get gateway,httproute -n "$AGW_NS" 2>/dev/null || true
    kc get enterpriseagentgatewaybackends -n "$AGW_NS" 2>/dev/null || true
    ;;
  *) usage ;;
esac
