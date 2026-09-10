#!/usr/bin/env bash
# sandbox-probe.sh — what the gateway's code sandbox will and will not give a program.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JS='const p={}; for (const n of ["Date","fetch","Math","JSON","Promise","Map","console","process","require"]) { try { p[n]=typeof eval(n); } catch(e) { p[n]="MISSING"; } } p'
"$HERE/mcp.sh" tools/call "$(python3 -c 'import json,sys;print(json.dumps({"name":"run_code","arguments":{"code":sys.argv[1]}}))' "$JS")" \
  | python3 -c '
import json,sys
d=json.loads(json.load(sys.stdin)["result"]["content"][0]["text"])["success"]
for k,v in d.items():
    print("  %-10s %s" % (k, v))'
