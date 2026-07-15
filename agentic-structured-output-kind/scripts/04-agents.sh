#!/usr/bin/env bash
# 04-agents.sh — the record-tools MCP server, both DBA specialists, the SRE
# orchestrator, and the broken Postgres incident.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

step "record-tools MCP server (record_diagnosis holds the contract)"
kc apply -f "$LAB_ROOT/yaml/mcp/record-tools.yaml" >/dev/null
wait_deploy kagent record-tools 180s && ok "record-tools running" || warn "record-tools not Available"

step "Applying agents"
kc apply -f "$LAB_ROOT/yaml/agents/dba-agent-declarative.yaml" >/dev/null
kc apply -f "$LAB_ROOT/yaml/agents/dba-agent-byo.yaml" >/dev/null
kc apply -f "$LAB_ROOT/yaml/agents/sre-orchestrator.yaml" >/dev/null
ok "dba-agent-declarative + dba-agent-byo + sre-orchestrator applied"

step "Planting the broken 'orders' Postgres"
kc apply -f "$LAB_ROOT/yaml/incident/postgres.yaml" >/dev/null
ok "orders-db applied (no POSTGRES_PASSWORD -> crashloops)"

step "Waiting for the agents to be Ready"
wait_agent dba-agent-declarative 360 && ok "dba-agent-declarative Ready" || warn "dba-agent-declarative not Ready"
wait_agent dba-agent-byo 420         && ok "dba-agent-byo Ready"         || warn "dba-agent-byo not Ready"
wait_agent sre-orchestrator 360      && ok "sre-orchestrator Ready"      || warn "sre-orchestrator not Ready"
kc -n kagent get agent >&2 || true

step "Agents ready"
cat >&2 <<EOF
  Try the contract two ways:
    ./scripts/contract.sh declarative   # DBA via the record_diagnosis MCP tool
    ./scripts/contract.sh byo           # DBA via the ADK pydantic output_schema
  End to end (SRE investigates, delegates, folds in the verdict):
    ./scripts/ask.sh "the orders database won't start - investigate and fix"
EOF
