#!/usr/bin/env bash
# ac-invoke.sh "<prompt>" — invoke the agent's AWS Bedrock AgentCore runtime and
# print its reply. Defaults to the dice prompt.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
die(){ printf '  \033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
load_secrets
export AWS_REGION="${AWS_REGION:-us-east-1}"
# an AWS session: reuse the kernel's creds from §3b, else fall back to the profile
aws sts get-caller-identity >/dev/null 2>&1 || {
  [ -n "${AWS_PROFILE:-}" ] || die "no AWS session — run: source scripts/agentcore.sh first"
  eval "$(aws configure export-credentials --format env 2>/dev/null)" || true
  aws sts get-caller-identity >/dev/null 2>&1 || die "no AWS session — aws sso login --profile $AWS_PROFILE"
}

RUNTIME_NAME="${AC_RUNTIME_NAME:-agentdemo_agentcore}"
PROMPT="${*:-Roll a 20-sided die and tell me whether the result is a prime number.}"
# The deploy (§3b) was kicked off earlier and provisions in the background, so wait
# for the runtime to reach READY before invoking — up to ~5 min (usually already
# READY by the time you get here).
ARN=""; ST=""
for i in $(seq 1 30); do
  read -r ST ARN < <(aws bedrock-agentcore-control list-agent-runtimes --region "$AWS_REGION" 2>/dev/null \
    | jq -r --arg n "$RUNTIME_NAME" '.agentRuntimes[]? | select(.agentRuntimeName==$n) | "\(.status) \(.agentRuntimeArn)"') || true
  case "$ST" in
    READY)  break ;;
    FAILED) die "AgentCore runtime '$RUNTIME_NAME' is FAILED — re-run the deploy (§3b) and check $AGENTCORE_LOG" ;;
    "")     echo "waiting for AgentCore runtime '$RUNTIME_NAME' to appear… [$i/30]  (deploy log: ${TMPDIR:-/tmp}/agentcore-deploy.log)" ;;
    *)      echo "AgentCore runtime '$RUNTIME_NAME': $ST [$i/30]" ;;
  esac
  sleep 10
done
[[ "$ST" == "READY" && -n "$ARN" ]] || die "AgentCore runtime '$RUNTIME_NAME' not READY (status: ${ST:-missing}) — check the §3b deploy log"

PAYLOAD="$(PROMPT="$PROMPT" python3 -c 'import json,os;print(json.dumps({"jsonrpc":"2.0","id":"r1","method":"message/send","params":{"message":{"role":"user","messageId":"m1","parts":[{"kind":"text","text":os.environ["PROMPT"]}]}}}))')"
aws bedrock-agentcore invoke-agent-runtime --region "$AWS_REGION" --cli-binary-format raw-in-base64-out \
  --agent-runtime-arn "$ARN" --content-type application/json --accept application/json \
  --payload "$PAYLOAD" /tmp/ac-out.json >/dev/null
python3 - <<'PY'
import json
d=json.load(open('/tmp/ac-out.json'))
if 'error' in d:
    print('ERROR:', json.dumps(d['error'])); raise SystemExit
res = d.get('result', {})
def texts(parts):
    return [p['text'].strip() for p in (parts or [])
            if p.get('kind') == 'text' and isinstance(p.get('text'), str) and p['text'].strip()]
# The agent's FINAL answer is in result.artifacts[].parts[] — print just that, in order.
out = [t for a in (res.get('artifacts') or []) for t in texts(a.get('parts'))]
if not out:  # fallback: last non-user message in history; else the raw payload
    hist = [t for m in (res.get('history') or []) if m.get('role') != 'user' for t in texts(m.get('parts'))]
    out = hist[-1:] if hist else [json.dumps(res)[:2000]]
print('\n'.join(out))
PY
