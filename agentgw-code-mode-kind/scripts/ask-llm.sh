#!/usr/bin/env bash
# ask-llm.sh "<task>" — let Claude read the generated TypeScript API and write
# the JavaScript that run_code executes. This is code mode end to end.
#
#   ./scripts/ask-llm.sh "which categories have the most available pets?"
#   MODEL=claude-opus-4-8 ./scripts/ask-llm.sh "..."
#
# Needs ANTHROPIC_API_KEY (export it, or source your secrets file first).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require uv
load_secrets
[[ -n "${ANTHROPIC_API_KEY:-}" ]] || die "ANTHROPIC_API_KEY not set (export it, or use SECRETS_FILE=...)"
ensure_gw_pf
export ANTHROPIC_API_KEY
[[ -n "${MODEL:-}" ]] && export MODEL
step "Asking Claude to drive run_code at ${MCP_URL}"
uv_run ask_llm.py "$@"
