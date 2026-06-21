#!/usr/bin/env bash
# add-mcp.sh — wire an approved MCP tool server (from the registry catalog) into
# the already-scaffolded agent, the way the demo tells it: scaffold the agent,
# then come back and "add MCP". arctl v2026.5.4 has no `add-mcp` verb, so this is
# the equivalent syntactic sugar — it edits the agent's declarative metadata
# in place, no re-scaffold:
#
#   1. agent.yaml  — appends spec.mcpServers[] {kind: MCPServer, name, tag}.
#                    This is what the registry resolves at deploy time to stand
#                    up the tool server next to the agent on kagent/AgentCore.
#   2. .env        — points MCP_SERVERS_CONFIG at the tool server for LOCAL runs
#                    (`arctl run` reaches it on host.docker.internal:<port>; run
#                    the server in a second terminal with `arctl run ./<path>`).
#
# Usage:
#   ./scripts/add-mcp.sh everything-server@latest            # deploy + local (:3000)
#   ./scripts/add-mcp.sh my-mcp@latest --deploy-only         # agent.yaml only
#   AGENT_DIR=agentdemo LOCAL_PORT=3000 ./scripts/add-mcp.sh everything-server@latest

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

REF="${1:?usage: add-mcp.sh <namespace/name@tag> [--deploy-only]}"
DEPLOY_ONLY=0; [[ "${2:-}" == "--deploy-only" ]] && DEPLOY_ONLY=1

AGENT_DIR="${AGENT_DIR:-agentdemo}"
LOCAL_PORT="${LOCAL_PORT:-3000}"
NAME="${REF%@*}"                      # everything-server
TAG="${REF#*@}"; [[ "$TAG" == "$REF" ]] && TAG=latest
SHORT="${NAME#*/}"                    # everything-server

require yq
[[ -f "$AGENT_DIR/agent.yaml" ]] || die "no $AGENT_DIR/agent.yaml — scaffold the agent first"

# 1. agent.yaml: append the MCPServer ref unless it is already there.
if NAME="$NAME" yq -e '.spec.mcpServers[] | select(.name == env(NAME))' "$AGENT_DIR/agent.yaml" >/dev/null 2>&1; then
  log "$NAME already referenced in $AGENT_DIR/agent.yaml"
else
  NAME="$NAME" TAG="$TAG" yq -i \
    '.spec.mcpServers += [{"kind":"MCPServer","name":env(NAME),"tag":env(TAG)}]' \
    "$AGENT_DIR/agent.yaml"
  ok "added $NAME@$TAG to $AGENT_DIR/agent.yaml (spec.mcpServers)"
fi

# 2. .env: wire MCP_SERVERS_CONFIG for local `arctl run` (skip with --deploy-only).
if (( DEPLOY_ONLY == 0 )); then
  ENV_FILE="$AGENT_DIR/.env"
  URL="http://host.docker.internal:${LOCAL_PORT}/mcp"
  CFG="[{\"name\":\"${SHORT}\",\"type\":\"remote\",\"url\":\"${URL}\"}]"
  touch "$ENV_FILE"
  # drop any existing MCP_SERVERS_CONFIG line, then append the fresh one
  grep -v '^MCP_SERVERS_CONFIG=' "$ENV_FILE" > "$ENV_FILE.tmp" 2>/dev/null || true
  mv "$ENV_FILE.tmp" "$ENV_FILE"
  printf 'MCP_SERVERS_CONFIG=%s\n' "$CFG" >> "$ENV_FILE"
  ok "wired $ENV_FILE for local run -> $URL"
  log "local run: terminal 1  arctl run ./mcp/${SHORT}    terminal 2  arctl run ./${AGENT_DIR}"
fi

echo >&2
step "agent.yaml now references:"
yq '.spec.mcpServers' "$AGENT_DIR/agent.yaml" | sed 's/^/  /' >&2
