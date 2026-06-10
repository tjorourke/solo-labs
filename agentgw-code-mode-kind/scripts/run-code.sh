#!/usr/bin/env bash
# run-code.sh — send JavaScript to the run_code tool and print the result. No
# LLM: this is the bare mechanic. Pass your own JS to experiment:
#   ./scripts/run-code.sh 'const a = await findPetsByStatus({ query: { status: "sold" } }); a.length'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require uv
ensure_gw_pf
step "Calling run_code at ${MCP_URL}"
uv_run run_code.py "$@"
