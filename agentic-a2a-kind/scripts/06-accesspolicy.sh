#!/usr/bin/env bash
# 06-accesspolicy.sh — apply the identity-driven authz: Alice (field-fte) may use
# the orchestrator; the DBA specialist is reachable only via the orchestrator.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

step "Applying AccessPolicies"
kc apply -f "$LAB_ROOT/yaml/accesspolicy/allow-alice.yaml" >/dev/null
kc apply -f "$LAB_ROOT/yaml/accesspolicy/scope-dba.yaml" >/dev/null
ok "AccessPolicies applied"
kc -n kagent get accesspolicies 2>/dev/null | sed 's/^/  /' >&2 || true

step "AccessPolicies ready"
echo "  Mint Alice's token:  ./scripts/mint-token.sh" >&2
echo "  Ask as Alice:        ./scripts/ask.sh \"the orders database won't start - fix it\"" >&2
