#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
tools
chain
rogue=$(k -n bank create token rogue-agent --duration=10m)
exchange "$H1" "$rogue" payments-mcp | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d.get("error")=="unauthorized_client" and "does not match may_act" in d.get("error_description",""),d
print("Rogue agent: REFUSED")
print("Service error:",d["error"])
print("Priya did not delegate to this agent.")'
bash "$LAB/scripts/capture-02.sh"
