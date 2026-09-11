#!/usr/bin/env bash
# show-card.sh <agent>: the agent card, straight from the agent's own pod.
#
# This is kagent's readiness probe. No card, no Ready. Both well-known paths are tried,
# because the A2A spec moved from agent.json to agent-card.json and runtimes differ.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
AGENT="${1:?usage: show-card.sh <agent>}"
agent_pf "$AGENT"
# A runtime whose JSON-RPC handler answers every path returns 200 with an error body
# for the second path, so the body is checked for a card, not just the status.
for path in /.well-known/agent-card.json /.well-known/agent.json; do
  if curl -s -m 5 "$AGENT_URL$path" | python3 -c 'import json,sys; c=json.load(sys.stdin); sys.exit(0 if "name" in c and "skills" in c else 1)' 2>/dev/null; then
    echo "GET $path → an agent card" >&2
  else
    echo "GET $path → not a card" >&2
  fi
done
curl -s -m 5 "$AGENT_URL/.well-known/agent-card.json" | python3 -m json.tool
