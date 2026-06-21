#!/usr/bin/env bash
# quick.sh — orchestrator for agentregistry-agentcore-kind.
#   ./scripts/quick.sh up | agentcore | status | teardown | prereqs

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

case "${1:-up}" in
  up)
    require_secrets
    bash "$SCRIPT_DIR/01-cluster.sh"
    bash "$SCRIPT_DIR/02-keycloak.sh"
    bash "$SCRIPT_DIR/03-kagent.sh"
    bash "$SCRIPT_DIR/04-agentregistry.sh"
    bash "$SCRIPT_DIR/05-scaffold.sh"
    bash "$SCRIPT_DIR/06-build-publish.sh"
    bash "$SCRIPT_DIR/07-runtime-deploy.sh"
    echo ""
    cat >&2 <<EOF
══════════════════════════════════════════════════════════════════
  agentregistry-agentcore-kind — UP
══════════════════════════════════════════════════════════════════

  Context: $CTX      Registry UI: ${ARCTL_API_BASE_URL}

  Three artifacts built with arctl and published to the catalog:
    acme/textkit (MCPServer)  summary-style (Skill)  summarizer (Agent)
  The summarizer is deployed onto the kind-kagent Runtime and hosted by
  the kagent controller.

    ./scripts/ask.sh "summarize this: <paste text with a couple of links>"
    ./scripts/port-forward.sh            # kagent dashboard at http://localhost:8080

  Local-only proof (no cluster):  ./scripts/test-local.sh
  Same agent on AWS:              ./scripts/quick.sh agentcore   # -> AWS Bedrock AgentCore
  Teardown everything:            ./scripts/cleanup.sh
EOF
    ;;
  agentcore)
    # Needs a live AWS session first:  aws sso login --profile <profile>
    bash "$SCRIPT_DIR/08-agentcore.sh"
    ;;
  prereqs)
    bash "$SCRIPT_DIR/00-prereqs.sh"
    ;;
  setup-env)
    bash "$SCRIPT_DIR/setup-env.sh"
    ;;
  setup|platform)
    # Engineer pre-demo: prereqs + platform only (no demo steps). For the
    # customer-facing notebook that starts at the scaffold step.
    bash "$SCRIPT_DIR/setup.sh"
    ;;
  reset)
    # Back to start: clear scaffold + deployments + catalog + AWS, keep platform.
    bash "$SCRIPT_DIR/reset.sh"
    ;;
  teardown)
    # AWS AgentCore bits first (no-ops cleanly with no live AWS session), then local.
    bash "$SCRIPT_DIR/cleanup.sh" agentcore
    step "Deleting kind cluster '$CLUSTER_NAME'"
    kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME" && { kind delete cluster --name "$CLUSTER_NAME"; ok "deleted"; } || log "not present"
    step "Removing the local registry container '$REG_NAME'"
    docker rm -f "$REG_NAME" >/dev/null 2>&1 && ok "registry removed" || log "registry not present"
    ;;
  status)
    step "registry runtimes"; arctl get runtimes 2>/dev/null | sed 's/^/  /' >&2 || log "arctl not logged in"
    step "catalog"; { arctl get mcp acme/textkit; arctl get skill summary-style; arctl get agent summarizer; arctl get runtimes; } 2>/dev/null | sed 's/^/  /' >&2 || true
    step "keycloak"; kc -n "$KEYCLOAK_NS" get pods 2>/dev/null | sed 's/^/  /' >&2 || true
    step "kagent"; kc -n kagent get agent,pods 2>/dev/null | sed 's/^/  /' >&2 || true
    ;;
  *) echo "Usage: $0 setup-env | setup | prereqs | up | agentcore | reset | status | teardown" >&2; exit 2;;
esac
