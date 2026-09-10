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
AGENT_DIR="$(cd "$HERE/.." && pwd)"          # agents/prtriage
PROJECT="$AGENT_DIR/adk-python"              # next to java-agent/
FORCE="${FORCE:-}"

if [ -d "$PROJECT" ] && [ -z "$FORCE" ]; then
  echo "adk-python/ already scaffolded (FORCE=1 to start over)"
else
  rm -rf "$PROJECT" "$AGENT_DIR/prtriage"
  # arctl names the project directory after the agent, and the agent has to stay
  # `prtriage` because the image, the catalogue entry and the kagent Agent all use it.
  # So scaffold and then rename the directory to sit alongside java-agent/.
  arctl init agent prtriage --framework adk --language python \
    --model-provider anthropic --model-name claude-haiku-4-5 \
    --mcp github-mcp@latest \
    --description "Reports which open pull requests are ready to merge and which are blocked." \
    --output-dir "$AGENT_DIR" >/dev/null
  mv "$AGENT_DIR/prtriage" "$PROJECT"
  echo "✓ scaffolded $PROJECT"
fi

echo
echo "== what the scaffold shipped as tools =="
grep -oE '^(async )?def [a-z_]+' "$PROJECT/prtriage/agent.py" | sed 's/^/  /'

cp "$HERE/../agent/agent.py" "$PROJECT/prtriage/agent.py"
echo
echo "== after the swap =="
grep -oE '^(async )?def [a-z_]+' "$PROJECT/prtriage/agent.py" | sed 's/^/  /'
echo
echo "  the dice samples are gone; 'today' is the only local tool, and every GitHub"
echo "  capability arrives through the approved MCP server in the catalogue."
