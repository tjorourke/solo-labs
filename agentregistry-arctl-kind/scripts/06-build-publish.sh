#!/usr/bin/env bash
# 06-build-publish.sh — build the MCP + agent container images and push them to
# the local registry (localhost:5001), then publish all three artifacts to the
# AgentRegistry catalog. The skill is git-based, so it has no image to build.
#
# Apply order matters: the MCPServer must exist before the Agent that references
# it (arctl resolves spec.mcpServers at apply time).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

cd "$LAB_ROOT"
arctl_token  # refresh bearer in case this script is run on its own

step "Build + push the textkit MCP image"
arctl build "./$ARTIFACTS_DIR/textkit" --push
ok "textkit image pushed to localhost:${REG_PORT}"

step "Build + push the summarizer agent image"
arctl build "./$ARTIFACTS_DIR/summarizer" --push
ok "summarizer image pushed to localhost:${REG_PORT}"

step "Publish the MCP server, skill, and agent to the catalog"
arctl apply -f "$ARTIFACTS_DIR/textkit/mcp.yaml"
arctl apply -f "$ARTIFACTS_DIR/summary-style/skill.yaml"
arctl apply -f "$ARTIFACTS_DIR/summarizer/agent.yaml"
ok "published acme/textkit (MCPServer), summary-style (Skill), summarizer (Agent)"

step "Catalog"
{ arctl get mcp acme/textkit; arctl get skill summary-style; arctl get agent summarizer; } 2>/dev/null | sed 's/^/  /' >&2 || true

echo "  Next: ./scripts/07-runtime-deploy.sh" >&2
