#!/usr/bin/env bash
# show-tools.sh — what does the gateway expose over MCP? In code mode: one
# run_code tool whose description is the generated TypeScript API. Pass
# --standard to instead point at the Standard-mode backend (four separate tools)
# for contrast (apply yaml/backend-standard.yaml + a route to it first).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require uv
ensure_gw_pf
step "Listing MCP tools at ${MCP_URL}"
uv_run show_tools.py "$@"
