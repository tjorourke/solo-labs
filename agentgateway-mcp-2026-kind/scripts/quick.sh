#!/usr/bin/env bash
# Non-interactive end-to-end check for the E2E runner.
# Brings the lab up, runs discover + MRTR + Tasks through the gateway,
# asserts on the payloads, tears down. Prints PASS on success.
set -euo pipefail
cd "$(dirname "$0")/.."

cleanup() { kind delete cluster --name mcp-2026 >/dev/null 2>&1 || true; }
trap cleanup EXIT

./scripts/up.sh

GW=http://localhost:30080/mcp
META='{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"quick-e2e","version":"1.0.0"},"io.modelcontextprotocol/clientCapabilities":{"elicitation":{},"extensions":{"io.modelcontextprotocol/tasks":{}}}}'

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

echo "--- server/discover (retrying until the NodePort answers)"
D=""
for i in $(seq 1 30); do
  D=$(mcp server/discover "" "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server/discover\",\"params\":{\"_meta\":$META}}" || true)
  echo "$D" | grep -q '"2026-07-28"' && break
  sleep 2
done
echo "$D" | grep -q '"2026-07-28"' || { echo "FAIL: discover (last: $D)"; exit 1; }

echo "--- MRTR pause"
R1=$(mcp tools/call cleanup_files "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"tools/call\",\"params\":{\"name\":\"cleanup_files\",\"arguments\":{},\"_meta\":$META}}")
echo "$R1" | grep -q '"input_required"' || { echo "FAIL: expected input_required"; exit 1; }
STATE=$(echo "$R1" | jget "d['result']['requestState']")

echo "--- MRTR resume after full server rollout"
kubectl -n mcp-2026 rollout restart deploy/ops-mcp >/dev/null
kubectl -n mcp-2026 rollout status deploy/ops-mcp --timeout=180s >/dev/null
sleep 3
R2=$(mcp tools/call cleanup_files "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"tools/call\",\"params\":{\"name\":\"cleanup_files\",\"arguments\":{},\"inputResponses\":{\"confirm_cleanup\":{\"action\":\"accept\",\"content\":{\"confirm\":true}}},\"requestState\":\"$STATE\",\"_meta\":$META}}")
echo "$R2" | grep -q 'deleted 3 files' || { echo "FAIL: MRTR resume"; exit 1; }

echo "--- tampered requestState is rejected"
B=$(mcp tools/call cleanup_files "{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"tools/call\",\"params\":{\"name\":\"cleanup_files\",\"arguments\":{},\"inputResponses\":{\"confirm_cleanup\":{\"action\":\"accept\",\"content\":{\"confirm\":true}}},\"requestState\":\"${STATE%?}x\",\"_meta\":$META}}")
echo "$B" | grep -q 'invalid or expired requestState' || { echo "FAIL: tamper check"; exit 1; }

echo "--- task lifecycle"
C=$(mcp tools/call run_pipeline "{\"jsonrpc\":\"2.0\",\"id\":20,\"method\":\"tools/call\",\"params\":{\"name\":\"run_pipeline\",\"arguments\":{},\"_meta\":$META}}")
echo "$C" | grep -q '"resultType":"task"\|"resultType": "task"' || { echo "FAIL: expected task result"; exit 1; }
TID=$(echo "$C" | jget "d['result']['taskId']")

S=""
for i in $(seq 1 20); do
  sleep 2
  G=$(mcp tasks/get "$TID" "{\"jsonrpc\":\"2.0\",\"id\":21,\"method\":\"tasks/get\",\"params\":{\"taskId\":\"$TID\",\"_meta\":$META}}")
  S=$(echo "$G" | jget "d['result']['status']")
  [ "$S" = "input_required" ] && break
done
[ "$S" = "input_required" ] || { echo "FAIL: task never paused (last: $S)"; exit 1; }

mcp tasks/update "$TID" "{\"jsonrpc\":\"2.0\",\"id\":23,\"method\":\"tasks/update\",\"params\":{\"taskId\":\"$TID\",\"inputResponses\":{\"approve_deploy\":{\"action\":\"accept\",\"content\":{\"approve\":true}}},\"_meta\":$META}}" >/dev/null

for i in $(seq 1 10); do
  sleep 2
  G=$(mcp tasks/get "$TID" "{\"jsonrpc\":\"2.0\",\"id\":24,\"method\":\"tasks/get\",\"params\":{\"taskId\":\"$TID\",\"_meta\":$META}}")
  S=$(echo "$G" | jget "d['result']['status']")
  [ "$S" = "completed" ] && break
done
[ "$S" = "completed" ] || { echo "FAIL: task never completed (last: $S)"; exit 1; }
echo "$G" | grep -q 'release 2026.31 deployed' || { echo "FAIL: task result"; exit 1; }

echo "PASS"
