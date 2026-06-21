#!/usr/bin/env bash
# gcp-invoke.sh "<prompt>" — invoke the agent on its Google Vertex AI Agent Engine
# runtime and print its reply. Defaults to the dice prompt. Mirrors ac-invoke.sh
# (AgentCore), but talks to the Vertex Reasoning Engine :streamQuery API.
#
# Auth uses your gcloud user token (the demo operator is logged in); the agent
# itself runs as the GeminiAgentRuntime service account.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.arctl/bin:$PATH"

AGENT="${AGENT:-agentdemo}"               # Vertex displayName of the deployed agent
LOCATION="${GCP_LOCATION:-us-central1}"
PROMPT="${*:-Roll a 20-sided die and tell me whether the result is a prime number.}"

command -v gcloud >/dev/null 2>&1 || die "gcloud not found — needed to reach Vertex AI"
PROJECT="${GCP_PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
[[ -n "$PROJECT" ]] || die "no GCP project — set GCP_PROJECT_ID or 'gcloud config set project <id>'"
TOK="$(gcloud auth print-access-token 2>/dev/null)"
[[ -n "$TOK" ]] || die "no gcloud token — run 'gcloud auth login'"
API="https://${LOCATION}-aiplatform.googleapis.com/v1"

# The deploy (§5b) provisions in the background (~6-10 min). Wait for the agent's
# reasoning engine to appear before invoking.
ENG=""
for i in $(seq 1 40); do
  ENG="$(curl -s -H "Authorization: Bearer $TOK" \
    "${API}/projects/${PROJECT}/locations/${LOCATION}/reasoningEngines" 2>/dev/null \
    | AGENT="$AGENT" python3 -c "import sys,json,os
d=json.load(sys.stdin)
for x in d.get('reasoningEngines',[]):
    if x.get('displayName')==os.environ['AGENT']: print(x['name']); break" 2>/dev/null)"
  [[ -n "$ENG" ]] && break
  echo "waiting for the Vertex agent '$AGENT' to appear… [$i/40]"; sleep 15
done
[[ -n "$ENG" ]] || die "Vertex agent '$AGENT' not found — deploy it first (§5b: source scripts/gcp.sh &)"

PAYLOAD="$(PROMPT="$PROMPT" python3 -c 'import json,os;print(json.dumps({"class_method":"stream_query","input":{"message":os.environ["PROMPT"],"user_id":"demo"}}))')"
STREAM="$(mktemp)"
curl -s -X POST -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" \
  "${API}/${ENG}:streamQuery?alt=sse" -d "$PAYLOAD" 2>/dev/null > "$STREAM"
python3 - "$STREAM" <<'PY'
import sys, json
# stream_query emits newline-delimited JSON events. The agent's final answer is the
# last model message whose parts carry text (not a function_call/response).
final = []
for line in open(sys.argv[1]):
    line = line.strip()
    if not line or line.startswith(":"):
        continue
    if line.startswith("data:"):
        line = line[5:].strip()
    try:
        ev = json.loads(line)
    except Exception:
        continue
    c = ev.get("content", {})
    if c.get("role") == "model":
        texts = [p["text"].strip() for p in c.get("parts", [])
                 if isinstance(p.get("text"), str) and p["text"].strip()]
        if texts:
            final = texts  # keep the latest model text turn
print("\n\n".join(final) if final else "(no text answer — check the raw stream)")
PY
rm -f "$STREAM"
