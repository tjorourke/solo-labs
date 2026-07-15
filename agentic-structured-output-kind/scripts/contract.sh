#!/usr/bin/env bash
# contract.sh [declarative|byo] — call a DBA specialist DIRECTLY over A2A with a
# fixed piece of incident evidence, and show exactly what rides back: any text
# part AND any structured data part. This is the crisp view of "one contract, two
# enforcements" — both agents answer in the same Diagnosis shape.
#
#   ./scripts/contract.sh declarative   # record_diagnosis MCP tool enforces it
#   ./scripts/contract.sh byo           # ADK pydantic output_schema enforces it
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

case "${1:-declarative}" in
  declarative|decl) AGENT="dba-agent-declarative";;
  byo|adk)          AGENT="dba-agent-byo";;
  *) die "usage: $0 [declarative|byo]";;
esac

# The evidence the SRE would hand over: the real crashloop log from orders-db.
read -r -d '' EVIDENCE <<'EOF' || true
Incident: the orders-db Postgres pod in namespace `orders` is in CrashLoopBackOff.
Its logs show, on every restart:

  Error: Database is uninitialized and superuser password is not specified.
  You must specify POSTGRES_PASSWORD to a non-empty value for the superuser.
  For example: -e POSTGRES_PASSWORD=password ... or POSTGRES_HOST_AUTH_METHOD=trust

The Deployment sets POSTGRES_DB=orders but no POSTGRES_PASSWORD.
Diagnose this and return the Diagnosis.
EOF

step "Calling $AGENT directly over A2A"
kc -n kagent port-forward svc/kagent-controller 8083:8083 >/tmp/contract-pf.$$ 2>&1 & CPF=$!
trap 'kill $CPF 2>/dev/null' EXIT
for _ in $(seq 1 20); do curl -s -o /dev/null "http://localhost:8083/api/a2a/kagent/${AGENT}/.well-known/agent.json" && break; sleep 1; done

RESP="$(curl -s -X POST "http://localhost:8083/api/a2a/kagent/${AGENT}/" \
  -H 'Content-Type: application/json' --max-time 240 \
  -d "{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"message/send\",\"params\":{\"message\":{\"role\":\"user\",\"parts\":[{\"kind\":\"text\",\"text\":$(printf '%s' "$EVIDENCE" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')}],\"messageId\":\"contract-$$\"}}}")"

echo "" >&2
printf '%s' "$RESP" | python3 -c '
import sys, json
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception:
    print(raw[:2000]); sys.exit()
if "error" in d:
    print("A2A error:", json.dumps(d["error"], indent=2)); sys.exit()

texts, datas = [], []
def walk(o):
    if isinstance(o, dict):
        k = o.get("kind")
        if k == "text" and isinstance(o.get("text"), str):
            t = o["text"].strip()
            if t and t not in texts: texts.append(t)
        elif k == "data" and "data" in o:
            datas.append(o["data"])
        for v in o.values(): walk(v)
    elif isinstance(o, list):
        for v in o: walk(v)
walk(d.get("result", d))

if datas:
    print("=== structured data part (DataPart) rode the A2A hop ===")
    for x in datas:
        print(json.dumps(x, indent=2))
    print()
if texts:
    print("=== text part ===")
    for t in texts:
        print(t)
if not datas and not texts:
    print(json.dumps(d, indent=2)[:2000])

# Is the text itself the strict contract shape?
import re
for t in texts:
    m = re.search(r"\{.*\}", t, re.S)
    if not m: continue
    try:
        obj = json.loads(m.group(0))
    except Exception:
        continue
    keys = set(obj) & {"root_cause","severity","fix","runbook_url"}
    if len(keys) >= 3:
        print()
        print("=== the text parses as the Diagnosis contract ===")
        print(json.dumps(obj, indent=2))
        break
'
echo "" >&2
