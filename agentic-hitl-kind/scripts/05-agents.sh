#!/usr/bin/env bash
# 05-agents.sh — apply both Ops Assistant agents.
#
#   declarative   — kagent CRD agent with requireApproval
#   langgraph     — BYO LangGraph agent (image must be loaded first)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_secrets

# Anthropic key secret used by the BYO LangGraph agent (the declarative agent
# picks it up from the chart-level providers.anthropic.apiKey installed in
# 03-kagent.sh, which writes the same kagent-anthropic Secret automatically).
step "Creating anthropic key secret for BYO agents"
kc -n kagent create secret generic kagent-anthropic \
  --from-literal=ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
ok "anthropic secret applied"

# ── Declarative agent ─────────────────────────────────────────────────────────
step "Applying declarative DBA Assistant"
kc apply -f "$LAB_ROOT/yaml/agents/declarative.yaml" >/dev/null
ok "dba-assistant agent applied"

# ── BYO LangGraph agent ───────────────────────────────────────────────────────
LANGGRAPH_DOCKERFILE="$LAB_ROOT/src/langgraph-agent/Dockerfile"
LANGGRAPH_YAML="$LAB_ROOT/yaml/agents/langgraph.yaml"

if [[ -f "$LANGGRAPH_DOCKERFILE" && -f "$LANGGRAPH_YAML" ]]; then
  step "Building + loading LangGraph agent image"
  build_and_load "$LAB_ROOT/src/langgraph-agent" "$LANGGRAPH_AGENT_IMAGE"

  step "Applying BYO LangGraph agent"
  kc apply -f "$LANGGRAPH_YAML" >/dev/null
  ok "dba-assistant-langgraph agent applied"
else
  warn "LangGraph agent not yet implemented — skipping (declarative agent only)"
fi

step "Agents ready"
echo "  kubectl --context $CTX -n kagent get agents" >&2
