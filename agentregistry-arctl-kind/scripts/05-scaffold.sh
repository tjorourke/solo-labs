#!/usr/bin/env bash
# 05-scaffold.sh — the three artifact projects under artifacts/ were scaffolded
# with `arctl init` and then customized (real tools, real SKILL.md, the agent
# wired to the MCP + skill). They are committed in the repo, so this step just
# verifies they are present and prints the init commands that produced them.
#
# To regenerate from scratch in an empty dir (and then re-apply the
# customizations), the commands were:
#
#   arctl init mcp acme/textkit   --framework fastmcp --language python
#   arctl init skill summary-style
#   arctl init agent summarizer   --framework adk --language python \
#       --model-provider anthropic --model-name claude-haiku-4-5 \
#       --local-mcp ./textkit

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

step "Verifying the scaffolded artifact projects"
cd "$LAB_ROOT"
missing=0
for f in "$ARTIFACTS_DIR/textkit/mcp.yaml" \
         "$ARTIFACTS_DIR/summary-style/skill.yaml" \
         "$ARTIFACTS_DIR/summarizer/agent.yaml"; do
  if [[ -f "$f" ]]; then ok "present: $f"; else warn "missing: $f"; missing=1; fi
done
(( missing == 0 )) || die "artifact projects incomplete — see README to regenerate with arctl init"

ok "all three artifact projects present (textkit MCP, summary-style skill, summarizer agent)"
echo "  Next: ./scripts/06-build-publish.sh" >&2
