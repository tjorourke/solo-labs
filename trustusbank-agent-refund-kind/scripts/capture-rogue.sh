#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
tools
python3 - "$LAB/scripts" <<'PY'
import sys, json
sys.path.insert(0,sys.argv[1])
from gateway_client import exchange
status, body = exchange('bob', 'rogue-agent', 'payments-mcp')
assert status >= 400 and 'may_act' in str(body), (status, body)
print('HTTP', status)
print(json.dumps(body, indent=2))
PY
