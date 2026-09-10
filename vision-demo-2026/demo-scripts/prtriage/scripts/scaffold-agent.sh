#!/usr/bin/env bash
# scaffold-agent.sh — arctl init the agent, then swap the sample tools out.
#
# `arctl init` writes a complete, runnable ADK + Python project, and the sample
# agent it gives you rolls dice. The project itself is a generated artifact (it is
# gitignored, like agentdemo/), so the one file we keep under source control is the
# agent.py that replaces the samples: ../agent/agent.py. This script scaffolds and
# then copies that over the top, which is the only edit the demo makes to the
# scaffold.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$HERE/../../.." && pwd)"
FORCE="${FORCE:-}"

if [ -d "$LAB_ROOT/prtriage" ] && [ -z "$FORCE" ]; then
  echo "prtriage/ already scaffolded (FORCE=1 to start over)"
else
  rm -rf "$LAB_ROOT/prtriage"
  arctl init agent prtriage --framework adk --language python \
    --model-provider anthropic --model-name claude-haiku-4-5 \
    --mcp github-mcp@latest \
    --description "Reports which open pull requests are ready to merge and which are blocked." \
    --output-dir "$LAB_ROOT" >/dev/null
  echo "✓ scaffolded $LAB_ROOT/prtriage"
fi

echo
echo "== what the scaffold shipped as tools =="
grep -oE '^(async )?def [a-z_]+' "$LAB_ROOT/prtriage/prtriage/agent.py" | sed 's/^/  /'

cp "$HERE/../agent/agent.py" "$LAB_ROOT/prtriage/prtriage/agent.py"
echo
echo "== after the swap =="
grep -oE '^(async )?def [a-z_]+' "$LAB_ROOT/prtriage/prtriage/agent.py" | sed 's/^/  /'
echo
echo "  the dice samples are gone; 'today' is the only local tool, and every GitHub"
echo "  capability arrives through the approved MCP server in the catalogue."
