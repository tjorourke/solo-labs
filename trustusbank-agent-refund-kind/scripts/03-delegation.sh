#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
tools
chain
printf '%s' "$H2" | claims | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d["preferred_username"] == "priya"
assert d["aud"] == "payments-mcp"
assert d["act"]["sub"] == "system:serviceaccount:bank:ledger-agent"
assert d["act"]["act"]["sub"] == "system:serviceaccount:bank:orchestrator"
print(json.dumps(d,indent=2))'
R=$(k -n bank create token rogue-agent --duration=10m)
result=$(exchange "$H1" "$R" payments-mcp)
printf '%s\n' "$result"
[[ "$result" == *'does not match may_act claim'* ]]
