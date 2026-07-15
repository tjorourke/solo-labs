#!/usr/bin/env bash
# contract.sh [declarative|byo] — call a DBA specialist DIRECTLY over A2A with a
# fixed piece of incident evidence. Prints (1) the FULL manifest(s) that define
# the agent and where the contract is enforced, and (2) the Diagnosis that rode
# back, normalised to the SAME bare shape for both paths so they compare directly.
#
#   ./scripts/contract.sh declarative   # record_diagnosis MCP tool enforces it
#   ./scripts/contract.sh byo           # ADK pydantic output_schema enforces it
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

case "${1:-declarative}" in
  declarative|decl)
    AGENT="dba-agent-declarative"
    MANIFESTS=("yaml/agents/dba-agent-declarative.yaml" "yaml/mcp/record-tools.yaml")
    SCHEMA_NOTE="the contract is the input schema of the record_diagnosis MCP tool (images/record-tools/record_tools/server.py)"
    ;;
  byo|adk)
    AGENT="dba-agent-byo"
    MANIFESTS=("yaml/agents/dba-agent-byo.yaml")
    SCHEMA_NOTE="the contract is the pydantic output_schema in images/dba-adk/dba/agent.py"
    ;;
  *) die "usage: $0 [declarative|byo]";;
esac

# ── 1. show the FULL manifest(s) that define this agent ───────────────────────
step "$AGENT — full manifest(s)"
for m in "${MANIFESTS[@]}"; do
  echo "# ---------- $m ----------"
  cat "$LAB_ROOT/$m"
  echo
done
echo "# note: $SCHEMA_NOTE"
echo

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

# ── 2. call the agent directly over A2A ───────────────────────────────────────
step "Calling $AGENT directly over A2A"
kc -n kagent port-forward svc/kagent-controller 8083:8083 >/tmp/contract-pf.$$ 2>&1 & CPF=$!
trap 'kill $CPF 2>/dev/null' EXIT
for _ in $(seq 1 20); do curl -s -o /dev/null "http://localhost:8083/api/a2a/kagent/${AGENT}/.well-known/agent.json" && break; sleep 1; done

RESP="$(curl -s -X POST "http://localhost:8083/api/a2a/kagent/${AGENT}/" \
  -H 'Content-Type: application/json' --max-time 240 \
  -d "{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"message/send\",\"params\":{\"message\":{\"role\":\"user\",\"parts\":[{\"kind\":\"text\",\"text\":$(printf '%s' "$EVIDENCE" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')}],\"messageId\":\"contract-$$\"}}}")"

echo "" >&2
# Normalise both paths to the SAME bare Diagnosis shape: unwrap the declarative
# DataPart's `args` (the record_diagnosis tool call) and parse the BYO text part.
printf '%s' "$RESP" | python3 -c '
import sys, json, re
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception:
    print(raw[:2000]); sys.exit()
if "error" in d:
    print("A2A error:", json.dumps(d["error"], indent=2)); sys.exit()

KEYS = {"root_cause", "severity", "fix", "runbook_url"}
def is_diag(o):
    return isinstance(o, dict) and len(KEYS & set(o)) >= 3

diag, arrived = None, None
# our own input echo, so we never mistake it for the answer
sent_marker = "Diagnose this and return the Diagnosis."

def walk(o):
    global diag, arrived
    if isinstance(o, dict):
        # a DataPart carrying the record_diagnosis tool call: args IS the contract
        if o.get("kind") == "data" and isinstance(o.get("data"), dict):
            data = o["data"]
            if is_diag(data.get("args")):
                diag, arrived = data["args"], "A2A DataPart (record_diagnosis tool call, unwrapped from .args)"
            elif is_diag(data):
                diag, arrived = data, "A2A DataPart"
        # a text part that is (or contains) strict JSON matching the contract
        if diag is None and o.get("kind") == "text" and isinstance(o.get("text"), str):
            t = o["text"]
            if sent_marker not in t:
                m = re.search(r"\{.*\}", t, re.S)
                if m:
                    try:
                        obj = json.loads(m.group(0))
                        if is_diag(obj):
                            diag, arrived = obj, "strict-JSON text part (pydantic output_schema)"
                    except Exception:
                        pass
        for v in o.values(): walk(v)
    elif isinstance(o, list):
        for v in o: walk(v)
walk(d.get("result", d))

if diag is None:
    print("Could not find the Diagnosis in the response. Raw:")
    print(json.dumps(d, indent=2)[:2000]); sys.exit()

# print the contract in a fixed field order so both paths render identically
ordered = {k: diag.get(k, "") for k in ["root_cause", "severity", "fix", "runbook_url"]}
print("How the contract arrived:", arrived)
print()
print(json.dumps(ordered, indent=2))
'
echo "" >&2

exit 0
