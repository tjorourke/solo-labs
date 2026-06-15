#!/usr/bin/env bash
# quick.sh — orchestrator for agent-frameworks-kind (standalone cluster).
#   ./quick.sh up | teardown | status
#
# `up` runs every numbered phase script (NN-*.sh) it finds, in order. Phases are
# added incrementally as the lab is built, so this stays runnable at each step:
#   01-cluster  02-keycloak  03-agentgateway  04-kagent   (enterprise bring-up)
#   05-scenario (broken checkout + k8s-ops MCP + gateway data path)
#   06-crews    (the five SRE crews: kagent-native, ADK, LangChain/LangGraph, CrewAI, AutoGen)
#   07-augment  (prompt-guard + ext-auth HITL + AccessPolicy + rate-limit)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

case "${1:-up}" in
  up)
    require_secrets
    for phase in "$SCRIPT_DIR"/[0-9][0-9]-*.sh; do
      [[ -e "$phase" ]] || { warn "no phase scripts found"; break; }
      bash "$phase"
    done
    echo ""
    cat >&2 <<EOF
══════════════════════════════════════════════════════════════════
  agent-frameworks-kind — UP
══════════════════════════════════════════════════════════════════

  Context: $CTX

  One incident (the broken 'checkout' Deployment in namespace 'incident'),
  one three-role SRE crew, built five ways. Alice (Keycloak, group field-fte)
  invokes a crew; kagent exchanges her token into an OBO token for the agent
  hop, and every LLM + tool call routes through enterprise agentgateway.

    ./scripts/ask.sh "the checkout service is down - investigate and fix it"
    AGENT=sre-crew-langgraph ./scripts/ask.sh "..."     # pick a framework crew

  Dashboard:  ./scripts/port-forward.sh     # http://localhost:8080
  Reset:      kubectl --context $CTX -n incident rollout restart deploy/checkout
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
    step "Incident"; kc -n incident get pods,deploy 2>/dev/null | sed 's/^/  /' >&2 || true
    ;;
  *) echo "Usage: $0 up | teardown | status" >&2; exit 2;;
esac
