#!/usr/bin/env bash
# mcp-from-pod.sh <deployment> <method> <params-file> — one MCP call at the waypoint,
# made from inside a pod so it carries that workload's own mesh identity.
#
# The body is passed as a FILE and posted with --post-file. Building it inline meant
# three levels of quoting (bash, then the shell inside kubectl exec, then JSON holding
# JavaScript) and it was unreadable and easy to break. The agent images have wget and
# no python3, hence wget.
set -euo pipefail
DEP="${1:?usage: mcp-from-pod.sh <deployment> <method> <params-file>}"
METHOD="${2:?}"; PARAMS_FILE="${3:?}"
K="kubectl --context ${CTX:-kind-mesh1}"
NS="${NS:-kagent}"
URL="${MCP_IN_CLUSTER:-http://github-mcp.${NS}.svc.cluster.local/}"

python3 - "$METHOD" "$PARAMS_FILE" > /tmp/mcp-body.json <<'PY'
import json, sys
method, params_file = sys.argv[1], sys.argv[2]
params = json.load(open(params_file)) if params_file != "-" else {}
print(json.dumps({"jsonrpc": "2.0", "id": 2, "method": method, "params": params}))
PY

$K -n "$NS" exec -i "deploy/$DEP" -- sh -c 'cat > /tmp/body.json; U="'"$URL"'"
  I='"'"'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}'"'"'
  S=$(wget -qS -O /dev/null --header="Content-Type: application/json" \
        --header="Accept: application/json, text/event-stream" --post-data="$I" "$U" 2>&1 \
      | grep -i mcp-session-id | awk "{print \$2}" | tr -d "\r")
  wget -q --content-on-error -O- --header="Content-Type: application/json" \
       --header="Accept: application/json, text/event-stream" \
       ${S:+--header="Mcp-Session-Id: $S"} --post-file=/tmp/body.json "$U" 2>/dev/null \
    | sed "s/^data: //" | grep -v "^event:" | grep .' < /tmp/mcp-body.json 2>/dev/null || true
