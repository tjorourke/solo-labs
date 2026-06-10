#!/usr/bin/env bash
# quick.sh — orchestrator for agentic-a2a-kind (standalone cluster).
#   ./quick.sh up | teardown | status

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

case "${1:-up}" in
  up)
    require_secrets
    bash "$SCRIPT_DIR/01-cluster.sh"
    bash "$SCRIPT_DIR/02-keycloak.sh"
    bash "$SCRIPT_DIR/03-agentgateway.sh"
    bash "$SCRIPT_DIR/04-kagent.sh"
    bash "$SCRIPT_DIR/05-agents.sh"
    bash "$SCRIPT_DIR/06-accesspolicy.sh"
    echo ""
    cat >&2 <<EOF
══════════════════════════════════════════════════════════════════
  agentic-a2a-kind — UP
══════════════════════════════════════════════════════════════════

  Context: $CTX

  Alice (Keycloak, group field-fte) calls the SRE orchestrator; the
  orchestrator delegates the DB incident to the dba-agent. kagent
  exchanges Alice's token into an OBO token (sub: alice, act.sub:
  <agent>) for the downstream hops.

    ./scripts/mint-token.sh                 # show Alice's inbound token (no act)
    ./scripts/ask.sh "the orders database won't start - fix it"   # call as Alice; show the exchange

  Dashboard:  ./scripts/port-forward.sh     # http://localhost:8080
  Reset DB:   kubectl --context $CTX -n orders rollout restart deploy/orders-db
  Teardown:   ./scripts/quick.sh teardown
EOF
    ;;
  teardown)
    step "Deleting kind cluster '$CLUSTER_NAME'"
    kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME" && { kind delete cluster --name "$CLUSTER_NAME"; ok "deleted"; } || log "not present"
    ;;
  status)
    step "Keycloak"; kc -n "$KEYCLOAK_NS" get pods 2>/dev/null | sed 's/^/  /' >&2 || true
    step "kagent"; kc -n kagent get pods 2>/dev/null | sed 's/^/  /' >&2 || true
    step "Agents + AccessPolicies"; kc -n kagent get agent,accesspolicies 2>/dev/null | sed 's/^/  /' >&2 || true
    step "Incident"; kc -n orders get pods 2>/dev/null | sed 's/^/  /' >&2 || true
    ;;
  *) echo "Usage: $0 up | teardown | status" >&2; exit 2;;
esac
