#!/usr/bin/env bash
# ask.sh <agent> "<question>": put a question to a hosted agent and watch it work.
#
# Opens a kagent session first, then sends message/stream through the controller with
# that session as the contextId. That is what makes the turn a conversation the UI can
# list: the UI reads sessions and their stored tasks, and a bare A2A call opens neither.
# Tool calls are printed as they stream; the answer is printed at the end.
#
#   ./scripts/ask.sh sre-reference "Which pods in sre-lab are unhealthy, and why?"
#   AS_USER=bob ./scripts/ask.sh ...      # a different Keycloak user
#   ASK_SESSION=<id> ./scripts/ask.sh ... # continue an existing session
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

AGENT="${1:?usage: ask.sh <agent> \"<question>\"}"
QUESTION="${2:-Which pods in $SRE_NS are unhealthy, and why?}"
controller_pf

SESSION="${ASK_SESSION:-$(open_session "$AGENT" "${QUESTION:0:60}")}"
[[ -n "$SESSION" ]] || die "could not open a session for $NS/$AGENT"
echo "session  $SESSION"
echo "agent    $NS/$AGENT"
echo

# The request the UI itself sends, streamed. curl -N keeps the SSE frames coming as
# they arrive; the Python reads them and prints the parts a person wants to see.
BODY=$(python3 -c 'import json,sys; print(json.dumps({"jsonrpc":"2.0","id":"1","method":"message/stream","params":{"message":{"role":"user","contextId":sys.argv[1],"messageId":"ask-1","parts":[{"kind":"text","text":sys.argv[2]}]}}}))' "$SESSION" "$QUESTION")
ccurl -N -m 600 -X POST "$CONTROLLER_URL/api/a2a/$NS/$AGENT/" \
  -H 'Content-Type: application/json' -H 'Accept: text/event-stream' -d "$BODY" \
| python3 -u -c '
import json, sys
calls, answer, done = 0, "", False
def show(data):
    global calls, answer
    if "args" in data:
        calls += 1
        args = data.get("args") or {}
        brief = ", ".join("%s=%s" % (k, json.dumps(v)) for k, v in args.items()) if isinstance(args, dict) else json.dumps(args)
        print("  %2d. %s(%s)" % (calls, data.get("name"), brief[:160]), flush=True)
buf = []
for raw in sys.stdin:
    line = raw.rstrip("\r\n")
    if line.startswith("data:"):
        buf.append(line[5:].strip()); continue
    if line or not buf:
        continue
    try:
        frame = json.loads("".join(buf))
    except json.JSONDecodeError:
        buf = []; continue
    buf = []
    if "error" in frame:
        print("A2A error:", json.dumps(frame["error"])[:400]); sys.exit(1)
    result = frame.get("result", {})
    kind = result.get("kind")
    if kind == "artifact-update":
        for p in result.get("artifact", {}).get("parts", []):
            if p.get("kind") == "text": answer = p["text"]
    elif kind == "status-update":
        msg = (result.get("status") or {}).get("message") or {}
        if msg.get("role") == "agent":
            for p in msg.get("parts", []):
                if p.get("kind") == "data": show(p.get("data", {}))
                elif p.get("kind") == "text" and p.get("text", "").strip(): answer = p["text"]
        if result.get("final"): done = True; break
print()
print(answer.strip() or "(the agent returned no text)")
if not done: print("\n(stream ended without a final frame)", file=sys.stderr)
'
