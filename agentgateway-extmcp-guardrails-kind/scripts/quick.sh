#!/usr/bin/env bash
# Non-interactive end-to-end check for the E2E runner.
# Brings the lab up, drives the guardrail through Pass / Deny / Mutate /
# FailClosed, asserts on each, tears down. Prints PASS on success.
set -euo pipefail
cd "$(dirname "$0")/.."

PF_PID=""
cleanup() {
  [ -n "$PF_PID" ] && kill "$PF_PID" >/dev/null 2>&1 || true
  kind delete cluster --name extmcp-guardrails >/dev/null 2>&1 || true
}
trap cleanup EXIT

./scripts/up.sh

kubectl -n extmcp-demo port-forward svc/extmcp-gw 8080:3000 >/tmp/extmcp-pf.log 2>&1 &
PF_PID=$!

mcp() { npx -y @modelcontextprotocol/inspector@0.21.2 --cli http://localhost:8080/mcp --transport http "$@"; }

echo "--- waiting for the tunnel and gateway to answer"
OK=""
for i in $(seq 1 30); do
  if OUT=$(mcp --method tools/list 2>&1); then OK=1; break; fi
  sleep 2
done
[ -n "$OK" ] || { echo "FAIL: gateway never answered tools/list (last: $OUT)"; exit 1; }

echo "--- tools/list carries the guardrail's annotation (Response mutate)"
echo "$OUT" | grep -q 'guardrail: requires X-Role: admin header' || { echo "FAIL: tools/list not mutated"; echo "$OUT"; exit 1; }

echo "--- search_contacts passes through untouched (Request pass)"
mcp --method tools/call --tool-name search_contacts | grep -q 'Priya Shah' || { echo "FAIL: search_contacts"; exit 1; }

echo "--- delete_contact without X-Role is denied (Request deny)"
DENY=$(mcp --method tools/call --tool-name delete_contact --tool-arg id=c-1 2>&1 || true)
echo "$DENY" | grep -qi 'admin\|denied\|permission' || { echo "FAIL: expected denial"; echo "$DENY"; exit 1; }

echo "--- delete_contact with X-Role: admin succeeds"
mcp --header "X-Role: admin" --method tools/call --tool-name delete_contact --tool-arg id=c-1 | grep -q 'deleted c-1' || { echo "FAIL: admin delete"; exit 1; }

echo "--- FailClosed: a guardrail-mcp outage blocks gated calls, even benign ones"
kubectl -n extmcp-demo scale deploy/guardrail-mcp --replicas=0
kubectl -n extmcp-demo wait --for=delete pod -l app=guardrail-mcp --timeout=60s
OUTAGE=$(mcp --method tools/call --tool-name search_contacts 2>&1 || true)
echo "$OUTAGE" | grep -qiE 'error|denied|unavailable|unreachable' || { echo "FAIL: expected FailClosed to block during outage"; echo "$OUTAGE"; exit 1; }
kubectl -n extmcp-demo scale deploy/guardrail-mcp --replicas=1
kubectl -n extmcp-demo rollout status deploy/guardrail-mcp --timeout=60s

echo "PASS"
