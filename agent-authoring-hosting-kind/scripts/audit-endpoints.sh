#!/usr/bin/env bash
# Inventory Gateway-attached routes and probe MCP initialize without credentials.
# Findings are reported, not used as a complete cluster security verdict.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../agent-authoring-contract-kind/scripts/lib.sh
source "$SCRIPT_DIR/../../agent-authoring-contract-kind/scripts/lib.sh"
python3 "$SCRIPT_DIR/audit-endpoints.py" --context "$CTX" --namespace "$NS" "$@"
