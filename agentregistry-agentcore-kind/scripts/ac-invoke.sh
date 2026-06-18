#!/usr/bin/env bash
# ac-invoke.sh "<prompt>" — invoke the agent's AWS Bedrock AgentCore runtime and
# print its reply. Defaults to the dice prompt.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
RUNTIME_NAME="${AC_RUNTIME_NAME:-agentdemo_agentcore}"
PROMPT="${*:-Roll a 20-sided die and tell me whether the result is a prime number.}"
ARN="$(aws bedrock-agentcore-control list-agent-runtimes --region "${AWS_REGION:-us-east-1}" 2>/dev/null \
  | jq -r --arg n "$RUNTIME_NAME" '.agentRuntimes[]? | select(.agentRuntimeName==$n) | .agentRuntimeArn')"
[[ -n "$ARN" ]] || die "AgentCore runtime '$RUNTIME_NAME' not found (deploy it first)"
PAYLOAD="$(PROMPT="$PROMPT" python3 -c 'import json,os;print(json.dumps({"jsonrpc":"2.0","id":"r1","method":"message/send","params":{"message":{"role":"user","messageId":"m1","parts":[{"kind":"text","text":os.environ["PROMPT"]}]}}}))')"
aws bedrock-agentcore invoke-agent-runtime --region "${AWS_REGION:-us-east-1}" --cli-binary-format raw-in-base64-out \
  --agent-runtime-arn "$ARN" --content-type application/json --accept application/json \
  --payload "$PAYLOAD" /tmp/ac-out.json >/dev/null
python3 - <<'PY'
import json
d=json.load(open('/tmp/ac-out.json')); seen=[]
def w(o):
    if isinstance(o,dict):
        if o.get('role')=='user': return
        if o.get('kind')=='text' and isinstance(o.get('text'),str):
            t=o['text'].strip()
            if t and t not in seen: seen.append(t)
        [w(v) for v in o.values()]
    elif isinstance(o,list): [w(v) for v in o]
print('ERROR:', json.dumps(d['error'])) if 'error' in d else (w(d) or print('\n\n'.join(seen) if seen else json.dumps(d)[:1200]))
PY
