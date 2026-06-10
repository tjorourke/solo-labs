#!/usr/bin/env bash
# quick.sh — orchestrator for agentregistry-arctl-kind.
#   ./scripts/quick.sh up | teardown | status

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

case "${1:-up}" in
  up)
    require_secrets
    bash "$SCRIPT_DIR/01-cluster.sh"
    bash "$SCRIPT_DIR/02-keycloak.sh"
    bash "$SCRIPT_DIR/03-kagent.sh"
    bash "$SCRIPT_DIR/04-daemon.sh"
    bash "$SCRIPT_DIR/05-scaffold.sh"
    bash "$SCRIPT_DIR/06-build-publish.sh"
    bash "$SCRIPT_DIR/07-runtime-deploy.sh"
    echo ""
    cat >&2 <<EOF
══════════════════════════════════════════════════════════════════
  agentregistry-arctl-kind — UP
══════════════════════════════════════════════════════════════════

  Context: $CTX      Registry UI: ${ARCTL_API_BASE_URL}

  Three artifacts built with arctl and published to the catalog:
    acme/textkit (MCPServer)  summary-style (Skill)  summarizer (Agent)
  The summarizer is deployed onto the kind-kagent Runtime and hosted by
  the kagent controller.

    ./scripts/ask.sh "summarize this: <paste text with a couple of links>"
    ./scripts/port-forward.sh            # kagent dashboard at http://localhost:8080

  Local-only proof (no cluster):  ./scripts/test-local.sh
  Teardown:                       ./scripts/quick.sh teardown
EOF
    ;;
  teardown)
    step "Deleting kind cluster '$CLUSTER_NAME'"
    kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME" && { kind delete cluster --name "$CLUSTER_NAME"; ok "deleted"; } || log "not present"
    step "Stopping the arctl daemon"
    arctl daemon stop >/dev/null 2>&1 && ok "daemon stopped" || log "daemon not running"
    step "Removing the local registry container '$REG_NAME'"
    docker rm -f "$REG_NAME" >/dev/null 2>&1 && ok "registry removed" || log "registry not present"
    ;;
  status)
    step "arctl daemon"; arctl daemon status 2>/dev/null | sed 's/^/  /' >&2 || log "not running"
    step "catalog"; { arctl get mcp acme/textkit; arctl get skill summary-style; arctl get agent summarizer; arctl get runtimes; } 2>/dev/null | sed 's/^/  /' >&2 || true
    step "keycloak"; kc -n "$KEYCLOAK_NS" get pods 2>/dev/null | sed 's/^/  /' >&2 || true
    step "kagent"; kc -n kagent get agent,pods 2>/dev/null | sed 's/^/  /' >&2 || true
    ;;
  *) echo "Usage: $0 up | teardown | status" >&2; exit 2;;
esac
