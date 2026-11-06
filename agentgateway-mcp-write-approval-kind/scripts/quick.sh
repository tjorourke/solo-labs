#!/usr/bin/env bash
# Non-interactive end-to-end check for the E2E runner.
# Brings the lab up, exercises get_users (unguarded) and delete_user (MRTR
# pause/resume + tamper check), tears down. Prints PASS on success.
set -euo pipefail
cd "$(dirname "$0")/.."

cleanup() { kind delete cluster --name mcp-write-approval >/dev/null 2>&1 || true; }
trap cleanup EXIT

./scripts/up.sh

GW=http://localhost:30080/mcp
META='{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"quick-e2e","version":"1.0.0"},"io.modelcontextprotocol/clientCapabilities":{"elicitation":{}}}'

mcp() {
  curl -s "$GW" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H 'MCP-Protocol-Version: 2026-07-28' \
    -H "Mcp-Method: $1" \
    ${2:+-H "Mcp-Name: $2"} \
    -d "$3" | sed -n 's/^data: //p'
}

jget() { python3 -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))" "$1"; }

echo "--- get_users (unguarded)"
G=$(mcp tools/call get_users "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"get_users\",\"arguments\":{},\"_meta\":$META}}")
echo "$G" | grep -q 'Priya Shah' || { echo "FAIL: expected user list"; exit 1; }

echo "--- delete_user without the elicitation capability: refused"
NOELICIT='{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"quick-e2e-noelicit","version":"1.0.0"},"io.modelcontextprotocol/clientCapabilities":{}}'
B0=$(mcp tools/call delete_user "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"delete_user\",\"arguments\":{\"id\":\"u-2\"},\"_meta\":$NOELICIT}}")
echo "$B0" | grep -q 'refusing to delete without confirmation' || { echo "FAIL: expected refusal"; exit 1; }

echo "--- delete_user: MRTR pause"
R1=$(mcp tools/call delete_user "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"tools/call\",\"params\":{\"name\":\"delete_user\",\"arguments\":{\"id\":\"u-2\"},\"_meta\":$META}}")
echo "$R1" | grep -q '"input_required"' || { echo "FAIL: expected input_required"; exit 1; }
STATE=$(echo "$R1" | jget "d['result']['requestState']")

echo "--- delete_user: MRTR resume (approved)"
R2=$(mcp tools/call delete_user "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"tools/call\",\"params\":{\"name\":\"delete_user\",\"arguments\":{\"id\":\"u-2\"},\"inputResponses\":{\"confirm_delete\":{\"action\":\"accept\",\"content\":{\"confirm\":true}}},\"requestState\":\"$STATE\",\"_meta\":$META}}")
echo "$R2" | grep -q 'deleted u-2' || { echo "FAIL: MRTR resume"; exit 1; }

echo "--- tampered requestState is rejected"
R3=$(mcp tools/call delete_user "{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"tools/call\",\"params\":{\"name\":\"delete_user\",\"arguments\":{\"id\":\"u-3\"},\"inputResponses\":{\"confirm_delete\":{\"action\":\"accept\",\"content\":{\"confirm\":true}}},\"requestState\":\"${STATE%?}x\",\"_meta\":$META}}")
echo "$R3" | grep -q 'invalid or expired requestState' || { echo "FAIL: tamper check"; exit 1; }

echo "--- delete_user: MRTR resume (declined)"
R4=$(mcp tools/call delete_user "{\"jsonrpc\":\"2.0\",\"id\":13,\"method\":\"tools/call\",\"params\":{\"name\":\"delete_user\",\"arguments\":{\"id\":\"u-3\"},\"_meta\":$META}}")
STATE3=$(echo "$R4" | jget "d['result']['requestState']")
R5=$(mcp tools/call delete_user "{\"jsonrpc\":\"2.0\",\"id\":14,\"method\":\"tools/call\",\"params\":{\"name\":\"delete_user\",\"arguments\":{\"id\":\"u-3\"},\"inputResponses\":{\"confirm_delete\":{\"action\":\"decline\"}},\"requestState\":\"$STATE3\",\"_meta\":$META}}")
echo "$R5" | grep -q 'declined; u-3 not removed' || { echo "FAIL: decline path"; exit 1; }

echo "PASS"
