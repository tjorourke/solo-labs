#!/usr/bin/env bash
# ask.sh "<prompt>" — the end-to-end story. Call the SRE orchestrator; it inspects
# the cluster, gathers the failing DB pod's evidence, DELEGATES to a DBA specialist
# over A2A, and folds the returned Diagnosis into its summary.
#
#   ./scripts/ask.sh "the orders database won't start - investigate and fix"
#   ./scripts/ask.sh "... use the ADK DBA"        # steer which specialist
#   AGENT=dba-agent-byo ./scripts/ask.sh "..."    # or call a specialist directly
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

AGENT="${AGENT:-sre-orchestrator}"
if [[ "$#" -gt 0 ]]; then PROMPT="$*"; elif [[ ! -t 0 ]]; then PROMPT="$(cat)"; else PROMPT="the orders database won't start - investigate and tell me the fix"; fi
PROMPT="$(printf '%s' "$PROMPT" | tr '\n' ' ' | sed 's/  */ /g')"

step "Calling $AGENT"
kc -n kagent port-forward svc/kagent-controller 8083:8083 >/tmp/ask-pf.$$ 2>&1 & CPF=$!
trap 'kill $CPF 2>/dev/null' EXIT
for _ in $(seq 1 20); do curl -s -o /dev/null "http://localhost:8083/api/a2a/kagent/${AGENT}/.well-known/agent.json" && break; sleep 1; done

RESP="$(curl -s -X POST "http://localhost:8083/api/a2a/kagent/${AGENT}/" \
  -H 'Content-Type: application/json' --max-time 300 \
  -d "{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"message/send\",\"params\":{\"message\":{\"role\":\"user\",\"parts\":[{\"kind\":\"text\",\"text\":$(printf '%s' "$PROMPT" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')}],\"messageId\":\"ask-$$\"}}}")"

echo "" >&2
printf '%s' "$RESP" | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: print(sys.stdin.read()[:2000]); sys.exit()
if "error" in d: print("A2A error:", json.dumps(d["error"])); sys.exit()
seen=[]
def w(o):
    if isinstance(o,dict):
        if o.get("kind")=="text" and isinstance(o.get("text"),str):
            t=o["text"].strip()
            if t and t not in seen: seen.append(t)
        [w(v) for v in o.values()]
    elif isinstance(o,list): [w(v) for v in o]
w(d.get("result",d)); print("\n\n".join(seen) if seen else json.dumps(d)[:2000])
'
echo "" >&2
