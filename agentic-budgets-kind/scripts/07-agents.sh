#!/usr/bin/env bash
# 07-agents.sh — build the BYO LangGraph agent image, then apply 2 kagent
# Agent CRs (dba/support). Each agent mounts the corresponding JWT from
# the kagent-ns Secret jwt-issuer wrote in step 04 as $LLM_JWT and passes it
# as a Bearer token on every /v1/chat/completions request.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

step "Building + loading LangGraph agent image"
build_and_load "$LAB_ROOT/src/langgraph-agent" "$LANGGRAPH_AGENT_IMAGE"

step "Applying 2 BYO LangGraph agents (dba / support)"
kc apply -f "$LAB_ROOT/yaml/agents/dba-agent.yaml" >/dev/null
kc apply -f "$LAB_ROOT/yaml/agents/support-agent.yaml" >/dev/null
ok "both team agents applied"

step "Agents ready"
echo "  kubectl --context $CTX -n kagent get agents" >&2
