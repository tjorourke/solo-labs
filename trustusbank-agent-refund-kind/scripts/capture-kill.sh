#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
pod=$(k -n bank get pods -l bank-agent=ledger-agent -o json | python3 -c 'import json,sys;ps=[p for p in json.load(sys.stdin)["items"] if not p["metadata"].get("deletionTimestamp") and any(c.get("type")=="Ready" and c.get("status")=="True" for c in p.get("status",{}).get("conditions",[]))];assert ps;print(ps[-1]["metadata"]["name"])')
uid=$(k -n bank get pod "$pod" -o jsonpath='{.metadata.uid}')
ip=$(k -n bank get pod "$pod" -o jsonpath='{.status.podIP}')
probe() {
  k -n bank exec deploy/orchestrator -- python -c 'import sys,urllib.request
try:
 with urllib.request.urlopen(sys.argv[1],timeout=5) as r: print("HTTP",r.status)
except Exception as e:
 print(type(e).__name__+": "+str(e));sys.exit(1)' "http://$ip:8080/.well-known/agent-card.json"
}
before=$(probe)
[[ "$before" == *'HTTP 200'* ]] || exit 1
printf 'Refunds agent before switch: %s\n' "$before"
printf 'Selected instance UID: %s\n' "$uid"
k -n bank label pod "$pod" trustusbank-instance="$uid" --overwrite >/dev/null
trap 'k -n bank label pod "$pod" trustusbank-instance- >/dev/null 2>&1 || true' EXIT
printf 'apiVersion: security.istio.io/v1\nkind: AuthorizationPolicy\nmetadata: {name: kill-ledger-instance, namespace: bank}\nspec:\n  selector:\n    matchLabels: {trustusbank-instance: "%s"}\n  action: DENY\n  rules: [{}]\n' "$uid" | apply_stdin
blocked=false
for attempt in {1..15}; do
  sleep 2
  if result=$(probe 2>&1); then continue; else blocked=true; break; fi
done
[[ "$blocked" == true ]] || { printf 'FAIL: selected instance still reachable\n' >&2; exit 1; }
printf 'Refunds agent after switch: REFUSED\n%s\n' "$result"
incurl --fail -o /dev/null -w 'Assistant still reachable: HTTP %{http_code}\n' http://orchestrator.bank.svc:8080/.well-known/agent-card.json
k -n bank label pod "$pod" trustusbank-instance- >/dev/null
trap - EXIT
