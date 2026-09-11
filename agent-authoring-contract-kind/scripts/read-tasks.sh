#!/usr/bin/env bash
# read-tasks.sh <session>: what the UI reads to draw a conversation.
#
# GET /api/sessions/{id}/tasks on the controller. A session with zero tasks is an empty
# chat, however well the agent answered. For each task the history roles are printed:
# the UI draws that list, not the artifacts.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
SESSION="${1:?usage: read-tasks.sh <session-id>}"
controller_pf
ccurl -m 20 "$CONTROLLER_URL/api/sessions/$SESSION/tasks" | python3 -c '
import json, sys
d = json.load(sys.stdin); t = d.get("data", d); t = t.get("tasks", t) if isinstance(t, dict) else t
print("tasks:", len(t or []))
for task in t or []:
    print("  task", task.get("id"), "state", (task.get("status") or {}).get("state"))
    print("  history roles:", " ".join(m.get("role", "?") for m in task.get("history", [])))
    for a in task.get("artifacts", []):
        for p in a.get("parts", []):
            if p.get("kind") == "text": print("  artifact:", p["text"][:200].replace("\n", " "), "...")
'
