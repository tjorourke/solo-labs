#!/usr/bin/env bash
# test-local.sh — prove the agent + MCP + skill work together locally, before any
# cluster. Starts the textkit MCP on the host (port 3000), then runs the agent
# with arctl. `arctl run` builds the agent, waits for its endpoint, and drops you
# into an interactive A2A chat. The agent's .env wires it to the local MCP via
# MCP_SERVERS_CONFIG (host.docker.internal:3000) and reads ANTHROPIC_API_KEY.
#
# Usage: ./scripts/test-local.sh   (Ctrl-C to exit the chat; the MCP is stopped)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

load_secrets
[[ -n "${ANTHROPIC_API_KEY:-}" ]] || die "ANTHROPIC_API_KEY required (export it or use SECRETS_FILE)"
cd "$LAB_ROOT"

step "Starting the textkit MCP on the host (http, :3000)"
( cd "$ARTIFACTS_DIR/textkit" && uv run python src/main.py --transport http --host 0.0.0.0 --port 3000 ) >/tmp/textkit-mcp.log 2>&1 &
MCP_PID=$!
trap 'kill "$MCP_PID" 2>/dev/null || true' EXIT
end=$(( $(date +%s) + 30 ))
until curl -sf http://127.0.0.1:3000/mcp -o /dev/null 2>&1 || [[ $(date +%s) -ge $end ]]; do sleep 1; done
ok "textkit MCP up (logs: /tmp/textkit-mcp.log)"

step "Running the summarizer agent (interactive A2A chat)"
log "try:  summarize this: <paste a paragraph with a couple of https:// links>"
ARCTL_API_TOKEN="${ARCTL_API_TOKEN:-}" arctl run "./$ARTIFACTS_DIR/summarizer"
