#!/usr/bin/env bash
# Non-interactive end-to-end check for the E2E runner.
# Brings the lab up, checks the ConfigMap policy (GET /policy), exercises
# get_users (allow via get_.*), delete_user (park/approve, park/reject via
# delete_.*), wipe_users (default deny, never parked) and GET /metrics,
# then tears down. Prints PASS on success.
#
# The EXIT trap deletes the kind cluster. Do not run this against a cluster
# someone is still reviewing.
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

ADMIN=http://localhost:8081
metric() { curl -s "$ADMIN/metrics" | awk -v m="$1" '$1==m {print $2}'; }

echo "--- /policy: shipped ConfigMap is loaded"
POLICY=$(curl -s "$ADMIN/policy")
echo "$POLICY" | python3 -c '
import json,sys
p=json.load(sys.stdin)
assert p["servers"]["users-mcp"]["allow"]==["get_.*"] and p["servers"]["users-mcp"]["approve"]==["delete_.*"] and p["servers"]["users-mcp"]["deny"]==[], p
assert p["path"]=="/etc/hitl/policy.yaml" and "error" not in p, p
' || { echo "FAIL: /policy"; echo "$POLICY"; exit 1; }

echo "--- tools/list"
mcp --method tools/list | grep -q '"delete_user"' || { echo "FAIL: tools/list"; exit 1; }

echo "--- get_users: passes straight through"
mcp --method tools/call --tool-name get_users | grep -q 'Priya Shah' || { echo "FAIL: get_users"; exit 1; }

echo "--- delete_user u-2: parks, then approve"
mcp --method tools/call --tool-name delete_user --tool-arg id=u-2 > /tmp/qa-delete-u2.out 2>&1 &
CALL_PID=$!
sleep 3
PID=$(curl -s http://localhost:8081/pending | python3 -c "import json,sys; print(json.load(sys.stdin)['pending'][0]['id'])")
echo "--- /metrics while parked"
[ "$(metric 'hitl_extauth_pending')" = "1" ] || { echo "FAIL: pending gauge"; exit 1; }
[ "$(metric 'hitl_extauth_approval_needed_total{server="users-mcp",tool="delete_user"}')" = "1" ] || { echo "FAIL: approval_needed_total"; exit 1; }
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

echo "--- wipe_users: matches no list, denied without parking"
WIPE=$(mcp --method tools/call --tool-name wipe_users 2>&1 || true)
echo "$WIPE" | grep -q 'default deny' || { echo "FAIL: default deny"; echo "$WIPE"; exit 1; }
[ "$(curl -s "$ADMIN/pending")" = '{"pending":[]}' ] || { echo "FAIL: wipe_users was parked"; exit 1; }

echo "--- /metrics after the run"
[ "$(metric 'hitl_extauth_pending')" = "0" ] || { echo "FAIL: pending not 0"; exit 1; }
[ "$(metric 'hitl_extauth_decisions_total{result="approved"}')" = "1" ] || { echo "FAIL: approved count"; exit 1; }
[ "$(metric 'hitl_extauth_decisions_total{result="rejected"}')" = "1" ] || { echo "FAIL: rejected count"; exit 1; }
[ "$(metric 'hitl_extauth_verdicts_total{server="users-mcp",tool="wipe_users",verdict="deny"}')" = "1" ] || { echo "FAIL: deny verdict"; exit 1; }
curl -s "$ADMIN/metrics" | grep -q 'tool="none"' && { echo "FAIL: handshake counted as a verdict"; exit 1; }

echo "--- get_users: u-2 gone, u-3 still present"
RESULT=$(mcp --method tools/call --tool-name get_users)
echo "$RESULT" | grep -q 'Tom Reyes' && { echo "FAIL: u-2 still present"; exit 1; }
echo "$RESULT" | grep -q 'Aisha Bello' || { echo "FAIL: u-3 missing"; exit 1; }

echo "PASS"
