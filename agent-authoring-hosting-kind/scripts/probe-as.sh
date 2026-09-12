#!/usr/bin/env bash
# probe-as.sh <serviceaccount> [endpoint]: tools/list at an MCP endpoint, as that identity.
#
# Runs from a throwaway pod carrying the service account, so the call reaches the
# waypoint with that workload's SPIFFE identity and nothing else. Prints the tool names
# the gateway generated for it; an identity the policy does not name gets none.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../agent-authoring-contract-kind/scripts/lib.sh
source "$SCRIPT_DIR/../../agent-authoring-contract-kind/scripts/lib.sh"
SA="${1:?usage: probe-as.sh <serviceaccount> [endpoint-url]}"
URL="${2:-http://contained-tools.$NS.svc.cluster.local/mcp}"
kc -n "$NS" get sa "$SA" >/dev/null 2>&1 || die "no service account $SA in $NS (is that agent deployed?)"
PROBE="probe-$SA-$RANDOM"
kc -n "$NS" run "$PROBE" --restart=Never --image=curlimages/curl:8.10.1 --env="URL=$URL" \
  --overrides="{\"spec\":{\"serviceAccountName\":\"$SA\"}}" --quiet -- sh -c '
INIT='"'"'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}'"'"'
H="-H Content-Type:application/json -H Accept:application/json,text/event-stream"
SID=$(curl -s -m 10 -D - -o /dev/null $H -d "$INIT" "$URL" | tr -d "\r" | awk "tolower(\$1)==\"mcp-session-id:\"{print \$2}")
curl -s -m 10 $H -H "Mcp-Session-Id: $SID" -d '"'"'{"jsonrpc":"2.0","id":2,"method":"tools/list"}'"'"' "$URL" | sed "s/^data: //" | grep "^{" | head -1
' >/dev/null
kc -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/"$PROBE" --timeout=120s >/dev/null 2>&1 || warn "probe $PROBE did not finish"
OUT="$(kc -n "$NS" logs "$PROBE" 2>/dev/null || true)"
kc -n "$NS" delete pod "$PROBE" --wait=false >/dev/null 2>&1 || true
echo "$OUT" | grep '^{' | python3 -c '
import json, sys
d = json.load(sys.stdin); tools = sorted(t["name"] for t in d.get("result", {}).get("tools", []))
print("as %s: %d tool(s)%s" % (sys.argv[1], len(tools), (": " + " ".join(tools)) if tools else ""))' "$SA" \
  || echo "as $SA: no MCP response (the endpoint refused the connection or the identity)"
