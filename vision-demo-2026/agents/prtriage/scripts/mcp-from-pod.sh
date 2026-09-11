#!/usr/bin/env bash
# mcp-from-pod.sh <deployment> <method> <params-file> — one MCP call at the waypoint,
# made from inside a pod so it carries that workload's own mesh identity.
#
# WHY THIS IS FUSSIER THAN IT LOOKS
# The pods this runs in are not ours and have no common toolbox: the Java agent images
# have wget and no python, and my-mcp has python and neither wget nor curl. An earlier
# version assumed wget, so in a pod without it the call produced NOTHING, and nothing
# is exactly what a denied call looks like. That turned a missing binary into a fake
# "policy refused it" row in the identity matrix. So: pick whatever the pod actually
# has, and if it has none of them, say so loudly rather than returning empty.
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

# Exit 3, distinctly, when there is no such workload: "the deployment is not there" and
# "the gateway refused it" are different answers and must never print the same.
$K -n "$NS" get "deploy/$DEP" >/dev/null 2>&1 || {
  echo "mcp-from-pod: no deploy/$DEP in namespace $NS, so there is nothing to probe." >&2
  echo "  This is NOT a policy denial." >&2
  exit 3
}

have() { $K -n "$NS" exec "deploy/$DEP" -- sh -c "command -v $1 >/dev/null 2>&1" 2>/dev/null; }
if   have wget;    then TRANSPORT=wget
elif have curl;    then TRANSPORT=curl
elif have python3; then TRANSPORT=python3
else
  echo "mcp-from-pod: deploy/$DEP has no wget, curl or python3, so it cannot be probed." >&2
  echo "  This is NOT a policy denial. Use a pod that can make an HTTP request." >&2
  exit 2
fi

case "$TRANSPORT" in
wget|curl)
  $K -n "$NS" exec -i "deploy/$DEP" -- sh -c 'cat > /tmp/body.json; U="'"$URL"'"
    I='"'"'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}'"'"'
    if command -v wget >/dev/null 2>&1; then
      S=$(wget -qS -O /dev/null --header="Content-Type: application/json" \
            --header="Accept: application/json, text/event-stream" --post-data="$I" "$U" 2>&1 \
          | grep -i mcp-session-id | awk "{print \$2}" | tr -d "\r")
      wget -q --content-on-error -O- --header="Content-Type: application/json" \
           --header="Accept: application/json, text/event-stream" \
           ${S:+--header="Mcp-Session-Id: $S"} --post-file=/tmp/body.json "$U" 2>/dev/null
    else
      S=$(curl -sS -D- -o /dev/null -X POST -H "Content-Type: application/json" \
            -H "Accept: application/json, text/event-stream" -d "$I" "$U" 2>/dev/null \
          | grep -i mcp-session-id | awk "{print \$2}" | tr -d "\r")
      curl -sS -X POST -H "Content-Type: application/json" \
           -H "Accept: application/json, text/event-stream" \
           ${S:+-H "Mcp-Session-Id: $S"} --data-binary @/tmp/body.json "$U" 2>/dev/null
    fi | sed "s/^data: //" | grep -v "^event:" | grep .' < /tmp/mcp-body.json 2>/dev/null || true
  ;;
python3)
  $K -n "$NS" exec -i "deploy/$DEP" -- python3 -c '
import json, sys, urllib.request, urllib.error
url = sys.argv[1]
body = sys.stdin.read().encode()
H = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
init = json.dumps({"jsonrpc":"2.0","id":1,"method":"initialize","params":{
    "protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}).encode()
sid = None
try:
    r = urllib.request.urlopen(urllib.request.Request(url, init, H), timeout=60)
    sid = r.headers.get("Mcp-Session-Id")
except urllib.error.HTTPError as e:
    sid = e.headers.get("Mcp-Session-Id")
except Exception as e:
    print(json.dumps({"error": {"message": "initialize failed: %s" % e}})); raise SystemExit
h = dict(H)
if sid: h["Mcp-Session-Id"] = sid
try:
    out = urllib.request.urlopen(urllib.request.Request(url, body, h), timeout=180).read().decode()
except urllib.error.HTTPError as e:
    out = e.read().decode()
except Exception as e:
    out = json.dumps({"error": {"message": str(e)}})
for line in out.splitlines():
    line = line[6:] if line.startswith("data: ") else line
    if line and not line.startswith("event:"):
        print(line)
' "$URL" < /tmp/mcp-body.json 2>/dev/null || true
  ;;
esac
