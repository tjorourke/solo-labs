#!/usr/bin/env bash
# audit-endpoints.sh: every way into this cluster's gateways, and whether each is closed.
#
# A waypoint is mesh-internal: traffic arrives over HBONE with a verified identity and
# policy applies. An HTTPRoute on an ingress Gateway publishes a hostname on a load
# balancer and is open until a policy on it says otherwise. So: list both, and probe
# every published route that fronts an agentgateway backend with no credential.
# Anything that answers 200 is reported as OPEN. Routes to a UI or an API with its own
# login are listed but not judged; they are not gateway backends. The report is the
# output; the exit code is always 0, so a neighbour's open route on a shared cluster is
# a finding to read, not a failure of this lab.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../agent-authoring-contract-kind/scripts/lib.sh
source "$SCRIPT_DIR/../../agent-authoring-contract-kind/scripts/lib.sh"

echo
echo "── waypoints (mesh-internal, identity on every connection) ──────────────────"
kc get gateway -A -o json | python3 -c '
import json, sys
for g in json.load(sys.stdin)["items"]:
    if "waypoint" in g["spec"].get("gatewayClassName", ""):
        addr = (g.get("status", {}).get("addresses") or [{}])[0].get("value", "-")
        print("  %-36s %s/%s" % (g["metadata"]["name"], g["metadata"]["namespace"], addr))'

echo
echo "── services that are not ClusterIP in $NS (should be none) ─────────────────"
kc -n "$NS" get svc -o json | python3 -c '
import json, sys
rows = [s for s in json.load(sys.stdin)["items"] if s["spec"].get("type", "ClusterIP") != "ClusterIP"]
print("  none" if not rows else "\n".join("  OPEN  %s type=%s" % (s["metadata"]["name"], s["spec"]["type"]) for s in rows))'

echo
echo "── published routes (ingress gateways) ─────────────────────────────────────"
OPEN=0
while IFS=$'\t' read -r ns name host backend_kind jwt; do
  [[ -n "$name" ]] || continue
  if [[ "$host" == *.svc.cluster.local || "$host" == "(any host)" ]]; then
    verdict="in-cluster hostname, not reachable from here (JWT policy: ${jwt:-none})"
  elif [[ "$backend_kind" == *Agentgateway* ]]; then
    code="$(curl -s -m 8 -o /dev/null -w '%{http_code}' -X POST "http://$host/mcp" -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"audit","version":"1"}}}')" || code="000"
    if [[ "$code" == 401 || "$code" == 403 ]]; then verdict="closed (HTTP $code without a token, JWT policy: ${jwt:-none})"
    elif [[ "$code" == 200 ]]; then verdict="OPEN  (HTTP 200 without a token, JWT policy: ${jwt:-none})"; OPEN=$((OPEN+1))
    else verdict="HTTP $code without a token, JWT policy: ${jwt:-none}"; fi
  else
    verdict="not a gateway backend ($backend_kind), has its own login"
  fi
  printf '  %-44s %s\n' "$host" "$verdict"
done < <(kc get httproute -A -o json | python3 -c '
import json, sys, subprocess
routes = json.load(sys.stdin)["items"]
pols = json.loads(subprocess.check_output(["kubectl", "--context", sys.argv[1], "get", "enterpriseagentgatewaypolicy", "-A", "-o", "json"]))["items"]
jwt_on = {}
for p in pols:
    if (p["spec"].get("traffic") or {}).get("jwtAuthentication"):
        for t in p["spec"].get("targetRefs", []):
            jwt_on[(p["metadata"]["namespace"], t.get("kind"), t["name"])] = p["metadata"]["name"]
for r in routes:
    ns, name = r["metadata"]["namespace"], r["metadata"]["name"]
    parent = (r["spec"].get("parentRefs") or [{}])[0]
    if parent.get("kind", "Gateway") != "Gateway": continue          # Service parentRef: a waypoint route
    hosts = r["spec"].get("hostnames") or ["(any host)"]
    kinds = {b.get("kind", "Service") for rule in r["spec"].get("rules", []) for b in rule.get("backendRefs", [])}
    jwt = jwt_on.get((ns, "HTTPRoute", name)) or jwt_on.get((parent.get("namespace", ns), "Gateway", parent.get("name")))
    for h in hosts:
        print("\t".join([ns, name, h, ",".join(sorted(kinds)), jwt or ""]))' "$CTX")
echo
if (( OPEN > 0 )); then echo "  $OPEN published gateway route(s) answer without a token. Each one needs a JWT policy, or should not be published."
else echo "  every published gateway route refuses a request without a token."; fi
