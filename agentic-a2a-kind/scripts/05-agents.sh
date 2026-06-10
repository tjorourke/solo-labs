#!/usr/bin/env bash
# 05-agents.sh — deploy the SRE orchestrator + DBA specialist (A2A delegation)
# and plant the broken Postgres incident.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

step "Applying agents"
kc apply -f "$LAB_ROOT/yaml/agents/dba-agent.yaml" >/dev/null
kc apply -f "$LAB_ROOT/yaml/agents/sre-orchestrator.yaml" >/dev/null
ok "dba-agent + sre-orchestrator applied"

step "Planting the broken 'orders' Postgres"
kc apply -f "$LAB_ROOT/yaml/incident/postgres.yaml" >/dev/null
ok "orders-db applied (no POSTGRES_PASSWORD -> crashloops)"

step "Waiting for both agents to be Ready"
wait_agent dba-agent 360        && ok "dba-agent Ready"        || warn "dba-agent not Ready"
wait_agent sre-orchestrator 360 && ok "sre-orchestrator Ready" || warn "sre-orchestrator not Ready"
kc -n kagent get agent dba-agent sre-orchestrator >&2 || true

step "Agents ready"; echo "  Next: ./scripts/06-accesspolicy.sh" >&2
