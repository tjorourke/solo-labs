#!/usr/bin/env bash
# report-to-github.sh <owner>/<repo> [path] [branch] — headless equivalent of
# prompting the reporter agent in the UI. Sends one A2A message to the
# port-audit-reporter agent telling it where to publish; the agent reads the
# report ConfigMap, renders markdown, and commits to the repo only if it changed.
#
#   ./scripts/report-to-github.sh tjorourke/solo-port-test
#   ./scripts/report-to-github.sh tjorourke/solo-port-test docs/port-audit.md main
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO="${1:-}"; PATH_IN_REPO="${2:-port-audit-report.md}"; BRANCH="${3:-main}"
[[ -n "$REPO" ]] || die "usage: report-to-github.sh <owner>/<repo> [path] [branch]"
OWNER="${REPO%%/*}"; NAME="${REPO##*/}"
PROMPT="Publish the port audit to ${OWNER}/${NAME} at ${PATH_IN_REPO} on ${BRANCH}."

step "Asking port-audit-reporter to publish to ${REPO} (${PATH_IN_REPO}@${BRANCH})"
kc -n kagent port-forward svc/kagent-controller 8083:8083 >/tmp/pa-report-pf.$$ 2>&1 & CPF=$!
trap 'kill $CPF 2>/dev/null' EXIT
for _ in $(seq 1 20); do
  curl -s -o /dev/null "http://localhost:8083/api/a2a/kagent/port-audit-reporter/.well-known/agent.json" && break
  sleep 1
done

RESP="$(curl -s -X POST "http://localhost:8083/api/a2a/kagent/port-audit-reporter/" \
  -H 'Content-Type: application/json' --max-time 300 \
  -d "{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"message/send\",\"params\":{\"message\":{\"role\":\"user\",\"parts\":[{\"kind\":\"text\",\"text\":$(printf '%s' "$PROMPT" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')}],\"messageId\":\"report-$$\"}}}")"

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
