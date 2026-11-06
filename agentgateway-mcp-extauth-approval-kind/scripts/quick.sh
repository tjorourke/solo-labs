#!/usr/bin/env bash
# Non-interactive end-to-end check for the E2E runner.
# Brings the lab up, exercises get_users (passthrough), delete_user
# (park/approve, park/reject), tears down. Prints PASS on success.
set -euo pipefail
cd "$(dirname "$0")/.."

cleanup() {
  kill "${PF_PID:-0}" 2>/dev/null || true
  kind delete cluster --name mcp-extauth-approval >/dev/null 2>&1 || true
}
trap cleanup EXIT

./scripts/up.sh

GW=http://localhost:30081/mcp
mcp() { npx -y @modelcontextprotocol/inspector@0.21.2 --cli "$GW" --transport http "$@"; }

kubectl -n mcp-extauth-demo port-forward svc/hitl-extauth-admin 8081:8081 >/tmp/qa-pf.log 2>&1 &
PF_PID=$!
sleep 2

echo "--- tools/list"
mcp --method tools/list | grep -q '"delete_user"' || { echo "FAIL: tools/list"; exit 1; }

echo "--- get_users: passes straight through"
mcp --method tools/call --tool-name get_users | grep -q 'Priya Shah' || { echo "FAIL: get_users"; exit 1; }

echo "--- delete_user u-2: parks, then approve"
mcp --method tools/call --tool-name delete_user --tool-arg id=u-2 > /tmp/qa-delete-u2.out 2>&1 &
CALL_PID=$!
sleep 3
PID=$(curl -s http://localhost:8081/pending | python3 -c "import json,sys; print(json.load(sys.stdin)['pending'][0]['id'])")
curl -s -X POST "http://localhost:8081/decide/$PID" -d '{"approved": true}' >/dev/null
wait "$CALL_PID"
grep -q '"deleted": "u-2"' /tmp/qa-delete-u2.out || { echo "FAIL: approved delete"; cat /tmp/qa-delete-u2.out; exit 1; }

echo "--- delete_user u-3: parks, then reject"
mcp --method tools/call --tool-name delete_user --tool-arg id=u-3 > /tmp/qa-delete-u3.out 2>&1 &
CALL_PID=$!
sleep 3
PID=$(curl -s http://localhost:8081/pending | python3 -c "import json,sys; print(json.load(sys.stdin)['pending'][0]['id'])")
curl -s -X POST "http://localhost:8081/decide/$PID" -d '{"approved": false, "reason": "no ticket"}' >/dev/null
wait "$CALL_PID" || true
grep -q 'approved.:false' /tmp/qa-delete-u3.out || { echo "FAIL: rejected delete"; cat /tmp/qa-delete-u3.out; exit 1; }

echo "--- get_users: u-2 gone, u-3 still present"
RESULT=$(mcp --method tools/call --tool-name get_users)
echo "$RESULT" | grep -q 'Tom Reyes' && { echo "FAIL: u-2 still present"; exit 1; }
echo "$RESULT" | grep -q 'Aisha Bello' || { echo "FAIL: u-3 missing"; exit 1; }

echo "PASS"
