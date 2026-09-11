#!/usr/bin/env bash
# stream-message.sh <agent> "<question>": message/stream, straight to the agent, every
# SSE frame printed as it arrives.
#
# This is the request the UI sends. The response is text/event-stream: status-update
# frames while the agent works (the user's message first, then working, then tool calls
# as data parts), an artifact-update with the answer, and a final status-update with
# final: true. Each frame is printed as one line: its kind, state and a short summary.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
AGENT="${1:?usage: stream-message.sh <agent> \"<question>\"}"
QUESTION="${2:-Which pods in $SRE_NS are unhealthy, and why?}"
agent_pf "$AGENT"
BODY=$(python3 -c 'import json,sys; print(json.dumps({"jsonrpc":"2.0","id":"1","method":"message/stream","params":{"message":{"role":"user","messageId":"stream-1","parts":[{"kind":"text","text":sys.argv[1]}]}}}))' "$QUESTION")
curl -s -N -m 600 -D - -X POST "$AGENT_URL/" -H 'Content-Type: application/json' -H 'Accept: text/event-stream' -d "$BODY" \
| python3 -u -c '
import json, sys
n = 0
for raw in sys.stdin:
    line = raw.rstrip("\r\n")
    if line.lower().startswith("content-type:"):
        print(line); continue
    if not line.startswith("data:"):
        continue
    n += 1
    r = json.loads(line[5:]).get("result", {})
    kind, state, note = r.get("kind"), (r.get("status") or {}).get("state", ""), ""
    msg = (r.get("status") or {}).get("message") or {}
    for p in msg.get("parts", []):
        if p.get("kind") == "text": note = "%s: %r" % (msg.get("role"), p["text"][:60])
        if p.get("kind") == "data": d = p["data"]; note = "tool %s %s" % (d.get("name"), "call" if "args" in d else "result")
    if kind == "artifact-update":
        note = "answer, %d chars, lastChunk=%s" % (sum(len(p.get("text","")) for p in r["artifact"]["parts"]), r.get("lastChunk"))
    if r.get("final"): note += "  final=true"
    print("%2d  %-15s %-10s %s" % (n, kind, state, note))
'
