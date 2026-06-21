#!/usr/bin/env bash
# 04c-publish-mcp.sh — publish the approved MCP tool servers to the catalog so
# they are available for the demo. The notebook scaffolds the agent live with
# `arctl init agent ... --mcp <ref>`, and that ref is validated against the
# catalog — so the MCP servers must already be published here, as one-time
# engineer pre-work, before the demo starts.
#
# Each server is built (image -> localhost:5001) and applied (MCPServer ->
# catalog). The images force HTTP transport (see the Dockerfile ENV) so the
# kagent MCPServer the registry generates at deploy time can reach them.
#
# Servers (under mcp/):
#   everything-server   sum, echo, to_uppercase, reverse_text
#   my-mcp              word_count

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

cd "$LAB_ROOT"
arctl_login   # log in to the in-cluster registry (in case this script runs on its own)

MCP_SERVERS=(everything-server my-mcp)

for s in "${MCP_SERVERS[@]}"; do
  step "Build + push the $s MCP image"
  arctl build "./mcp/$s" --push
  ok "$s image pushed to localhost:${REG_PORT}"

  step "Publish demo/$s to the catalog"
  arctl apply -f "mcp/$s/mcp.yaml"
  ok "published demo/$s (MCPServer)"
done

step "Publish the dice-game skill to the catalog"
arctl apply -f skill/dice-game/skill.yaml 2>&1 | sed 's/^/  /' >&2
ok "published dice-game (Skill)"

step "Approved catalog"
{ echo "tool servers:"; arctl get mcpservers; echo "skills:"; arctl get skills; } 2>/dev/null | sed 's/^/  /' >&2 || true

echo "  Next: the notebook scaffolds the agent with --mcp everything-server@latest --mcp my-mcp@latest" >&2
