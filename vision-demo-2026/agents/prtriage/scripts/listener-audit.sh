#!/usr/bin/env bash
# listener-audit.sh — every way into this cluster's gateways, and which of them are open.
#
# WHY
# Deploying an agent or an MCP server through kagent/AgentRegistry creates a WAYPOINT, which is
# mesh-internal: traffic arrives over HBONE with a verified SPIFFE identity and your authorization
# policy applies. Nothing is exposed by that.
#
# Putting an HTTPRoute on an INGRESS Gateway is a different act. It publishes a hostname on a
# LoadBalancer, and it is open to anything that can route to the address until you say otherwise.
# That is ordinary gateway behaviour, and it is easy to forget when the backend behind it holds a
# credential: a per-identity policy on the waypoint governs agents, and an unauthenticated ingress
# route beside it hands the same credential to anyone who finds the URL.
#
# So: list every listener, classify it, and PROBE the exposed ones with no credential.
set -uo pipefail
K="kubectl --context ${CTX:-kind-mesh1}"
OPEN=0

echo
echo "  ── waypoints (mesh-internal, identity-checked) ──────────────────────────────"
$K get gateway -A -o json | python3 -c '
import json,sys
for g in json.load(sys.stdin)["items"]:
    if "waypoint" in g["spec"].get("gatewayClassName",""):
        print("    %-34s %s/%s" % (g["metadata"]["name"], g["metadata"]["namespace"],
              (g.get("status",{}).get("addresses") or [{}])[0].get("value","-")))'
echo "    these are not reachable from outside the mesh, and your policy applies to them"

echo
echo "  ── ingress listeners (published, open until you authenticate them) ──────────"
# Only routes whose backend is an agentgateway backend are judged here. A UI or an API
# behind the same gateway answers 200 to anything and has its own authentication; calling
# that "OPEN" would be crying wolf, and a report that cries wolf gets ignored.
$K get httproute -A -o json | python3 -c '
import json,sys
rows=[]
for r in json.load(sys.stdin)["items"]:
    p=(r["spec"].get("parentRefs") or [{}])[0]
    if p.get("kind","Gateway") != "Gateway": continue     # Service parentRef == waypoint (GAMMA)
    kinds={b.get("kind") for rule in (r["spec"].get("rules") or [])
                          for b in (rule.get("backendRefs") or [])}
    mcp = "EnterpriseAgentgatewayBackend" in kinds or "AgentgatewayBackend" in kinds
    for h in (r["spec"].get("hostnames") or ["(no hostname)"]):
        rows.append((h, r["metadata"]["namespace"]+"/"+r["metadata"]["name"], "mcp" if mcp else "other"))
for h,route,kind in sorted(rows): print("%s\t%s\t%s" % (h,route,kind))' > /tmp/la-routes.tsv

while IFS=$'\t' read -r host route kind; do
  [ -z "$host" ] && continue
  if [ "$kind" != "mcp" ]; then
    printf "    %-5s %-44s %-22s not an agentgateway backend, check its own auth\n" "----" "$host" "$route"
    continue
  fi
  case "$host" in
    *.svc.cluster.local) note="in-cluster shortcut on a published route" ;;
    *) note="" ;;
  esac
  # An unauthenticated MCP initialize. 200 means anyone who reaches this host is in.
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 -X POST "http://$host/" \
        -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
        -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"audit","version":"1"}}}' 2>/dev/null)
  case "$code" in
    200) printf "    \033[31mOPEN\033[0m  %-44s %-22s %s\n" "$host" "$route" "$note"; OPEN=$((OPEN+1)) ;;
    401|403) printf "    \033[32mauth\033[0m  %-44s %-22s answered %s\n" "$host" "$route" "$code" ;;
    000) printf "    ----  %-44s %-22s not reachable from here\n" "$host" "$route" ;;
    *)   printf "    %-5s %-44s %-22s\n" "$code" "$host" "$route" ;;
  esac
done < /tmp/la-routes.tsv

echo
echo "  ── which of those front something holding a credential ─────────────────────"
$K get enterpriseagentgatewaybackend -A -o json | python3 -c '
import json,sys
for b in json.load(sys.stdin)["items"]:
    ns,n=b["metadata"]["namespace"],b["metadata"]["name"]
    s=json.dumps(b.get("spec",{}))
    if "secretRef" in s:
        print("    %-28s %s  holds a credential (policies.auth.secretRef)" % (n, ns))'
echo
if [ "$OPEN" -gt 0 ]; then
  echo "  $OPEN published route(s) answered an unauthenticated MCP initialize."
  echo "  Close them with spec.traffic.jwtAuthentication or apiKeyAuthentication on an"
  echo "  EnterpriseAgentgatewayPolicy targeting the Gateway or the HTTPRoute, or drop the route."
else
  echo "  no published route answered unauthenticated."
fi
echo
exit 0
