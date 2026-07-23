#!/usr/bin/env bash
# add-skill.sh — bake an approved skill from the catalog into the agent. The
# AgentRegistry Agent kind has no `skills` reference yet, so a skill is delivered
# by folding its SKILL.md guidance into the agent's system instruction at build
# time. This reads the local skill source and injects its body into the agent's
# build_instruction("""...""") default.
#
#   ./scripts/add-skill.sh dice-game
#
# Run after scaffolding the agent and before `arctl build`.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

SKILL="${1:?usage: add-skill.sh <skill-name>}"
AGENT_DIR="${AGENT_DIR:-$PROJECT_ROOT/agentdemo}"   # scaffolded at the lab root
SKILL_MD="$LAB_ROOT/skill/$SKILL/SKILL.md"
# arctl scaffolds a nested package: <agentdemo>/<agentdemo>/agent.py
AGENT_PY="$AGENT_DIR/$(basename "$AGENT_DIR")/agent.py"

[[ -f "$SKILL_MD" ]]  || die "skill not found: $SKILL_MD"
[[ -f "$AGENT_PY" ]]  || die "agent not found: $AGENT_PY (scaffold the agent first)"

SKILL_MD="$SKILL_MD" AGENT_PY="$AGENT_PY" SKILL="$SKILL" python3 - <<'PY'
import os, re, sys

skill_md = open(os.environ["SKILL_MD"]).read()
# strip YAML frontmatter (--- ... ---) -> just the guidance body
body = re.sub(r'^---\n.*?\n---\n', '', skill_md, count=1, flags=re.S).strip()

agent_py = os.environ["AGENT_PY"]
src = open(agent_py).read()

# replace the build_instruction("""...""") default with the skill body
pat = re.compile(r'build_instruction\(\s*"""(.*?)"""\s*\)', re.S)
if not pat.search(src):
    sys.exit("could not find build_instruction(\"\"\"...\"\"\") in agent.py")
new = pat.sub('build_instruction("""\n' + body.replace('\\', '\\\\') + '\n""")', src, count=1)
open(agent_py, "w").write(new)
print("✓ baked skill '%s' into %s system instruction" % (os.environ["SKILL"], agent_py))
PY
