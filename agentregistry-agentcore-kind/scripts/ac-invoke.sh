#!/usr/bin/env bash
# ac-invoke.sh "<prompt>" — invoke the agent's AWS Bedrock AgentCore runtime and
# print its reply. Defaults to the dice prompt.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
RUNTIME_NAME="${AC_RUNTIME_NAME:-agentdemo_agentcore}"
PROMPT="${*:-Roll a 20-sided die and tell me whether the result is a prime number.}"
# The deploy (§5) was kicked off earlier and provisions in the background, so wait
# for the runtime to reach READY before invoking — up to ~5 min (usually already
# READY by the time you get here).
ARN=""; ST=""
for i in $(seq 1 30); do
  read -r ST ARN < <(aws bedrock-agentcore-control list-agent-runtimes --region "${AWS_REGION:-us-east-1}" 2>/dev/null \
    | jq -r --arg n "$RUNTIME_NAME" '.agentRuntimes[]? | select(.agentRuntimeName==$n) | "\(.status) \(.agentRuntimeArn)"')
  case "$ST" in
    READY)  break ;;
    FAILED) die "AgentCore runtime '$RUNTIME_NAME' is FAILED — re-run the deploy (§5)" ;;
    "")     echo "waiting for AgentCore runtime '$RUNTIME_NAME' to appear… [$i/30]" ;;
    *)      echo "AgentCore runtime '$RUNTIME_NAME': $ST [$i/30]" ;;
  esac
  sleep 10
done
[[ "$ST" == "READY" && -n "$ARN" ]] || die "AgentCore runtime '$RUNTIME_NAME' not READY (status: ${ST:-missing}) — deploy it first (§5)"
PAYLOAD="$(PROMPT="$PROMPT" python3 -c 'import json,os;print(json.dumps({"jsonrpc":"2.0","id":"r1","method":"message/send","params":{"message":{"role":"user","messageId":"m1","parts":[{"kind":"text","text":os.environ["PROMPT"]}]}}}))')"
aws bedrock-agentcore invoke-agent-runtime --region "${AWS_REGION:-us-east-1}" --cli-binary-format raw-in-base64-out \
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
# Fallback: last non-user message in history; else the raw payload.
if not out:
    for m in res.get('history') or []:
        if m.get('role') != 'user':
            out = texts(m.get('parts')) or out
print('\n\n'.join(out) if out else json.dumps(d)[:1200])
PY
