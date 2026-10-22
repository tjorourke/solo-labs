#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
tools
python3 - "$LAB/scripts" <<'PY'
import sys, json
sys.path.insert(0,sys.argv[1])
from gateway_client import exchange, claims
code, result = exchange('bob', 'refunds-agent', 'payments-mcp')
assert code == 200
token = claims(result['access_token'])
assert token['act']['sub'] == 'system:serviceaccount:bank:refunds-agent'
assert token['aud'] == 'payments-mcp'
assert 'payments-ops' in token['groups']
print(json.dumps({k: token[k] for k in ['sub', 'act', 'aud', 'groups']}, indent=2))
PY
