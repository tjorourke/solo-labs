#!/usr/bin/env bash
# send-message.sh <agent> "<question>": one JSON-RPC message/send, straight to the agent.
#
# The JSON path. The result is a Task with kind, id, contextId, status, artifacts and
# history. This goes to the agent's pod, not through the controller, so nothing is
# stored: the answer comes back and that is all that happens.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
AGENT="${1:?usage: send-message.sh <agent> \"<question>\"}"
QUESTION="${2:-Which pods in $SRE_NS are unhealthy, and why?}"
agent_pf "$AGENT"
BODY=$(python3 -c 'import json,sys; print(json.dumps({"jsonrpc":"2.0","id":"1","method":"message/send","params":{"message":{"role":"user","messageId":"send-1","parts":[{"kind":"text","text":sys.argv[1]}]}}}))' "$QUESTION")
curl -s -m 600 -X POST "$AGENT_URL/" -H 'Content-Type: application/json' -d "$BODY" | python3 -m json.tool
