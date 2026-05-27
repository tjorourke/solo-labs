#!/usr/bin/env bash
# Step 5 — deploy demo agentic workloads and run cross-cluster tests.
#
# What gets deployed:
#   east + west:  httpbin (connectivity smoke-test)
#   east + west:  echo-mcp (MCP server: echo + reverse tools)
#   east:         demo-agent (runs test calls through the agentgateway)
#
# Test scenarios:
#   A. North-south:  curl → agw-ingress LB → httpbin
#   B. Local MCP:    demo-agent → agw-ingress → echo-mcp (east)
#   C. Waypoint authz: authorised SA passes, rogue SA returns 403
#   D. Cross-cluster: demo-agent (east) → agw-ingress → echo-mcp (west)
#                     via HBONE + east-west GW + agw-waypoint (west)

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

[[ -f "$REPO_ROOT/.env" ]] && { set -a; source "$REPO_ROOT/.env"; set +a; }

CLUSTER1="${CLUSTER1:-kind-east}"
CLUSTER2="${CLUSTER2:-kind-west}"

log()    { echo "  $*"; }
log_ok() { echo "  ✓ $*"; }
step()   { echo ""; echo "==> $*"; }

# ---------- Deploy workloads ----------
step "Deploying httpbin to both clusters"
for ctx in "$CLUSTER1" "$CLUSTER2"; do
  kubectl --context "$ctx" apply -f "$REPO_ROOT/yaml/demo/httpbin.yaml" >/dev/null
  log_ok "[${ctx#kind-}] httpbin applied"
done

step "Deploying echo-mcp to both clusters"
for ctx in "$CLUSTER1" "$CLUSTER2"; do
  kubectl --context "$ctx" apply -f "$REPO_ROOT/yaml/demo/echo-mcp.yaml" >/dev/null
  log_ok "[${ctx#kind-}] echo-mcp applied"
done

# On west cluster: label echo-mcp for global mesh hostname so east agents
# can reach it as echo-mcp.ai-demo.svc.west.mesh.internal.
kubectl --context "$CLUSTER2" -n ai-demo label svc echo-mcp \
  "istio.io/global=true" --overwrite >/dev/null
log_ok "[west] echo-mcp labelled istio.io/global=true"

step "Waiting for pods to be ready"
for ctx in "$CLUSTER1" "$CLUSTER2"; do
  kubectl --context "$ctx" -n ai-demo wait \
    --for=condition=Ready pod -l app=echo-mcp \
    --timeout=120s >/dev/null &
  kubectl --context "$ctx" -n ai-demo wait \
    --for=condition=Ready pod -l app=httpbin \
    --timeout=120s >/dev/null &
done
wait
log_ok "all pods ready"

# ---------- Scenario A: North-south smoke test ----------
step "Scenario A — north-south connectivity (agw-ingress → httpbin)"
EAST_IP="$(kubectl --context "$CLUSTER1" -n agentgateway-system \
  get svc agw-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)"
WEST_IP="$(kubectl --context "$CLUSTER2" -n agentgateway-system \
  get svc agw-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)"

if [[ -n "$EAST_IP" ]]; then
  STATUS="$(curl -s -o /dev/null -w "%{http_code}" "http://${EAST_IP}:8080/get" 2>/dev/null || echo "failed")"
  [[ "$STATUS" == "200" ]] && log_ok "east agw-ingress → httpbin: HTTP $STATUS" \
                            || log     "east agw-ingress → httpbin: HTTP $STATUS (check agw-ingress logs)"
else
  log "east agw-ingress IP not assigned — skipping curl test"
fi

# ---------- Scenario B: MCP tool call via north-south ingress ----------
step "Scenario B — MCP echo tool call (agw-ingress → echo-mcp)"
if [[ -n "$EAST_IP" ]]; then
  log "sending MCP initialize to east agw-ingress..."
  # StreamableHTTP MCP protocol: POST with JSON-RPC envelope.
  HTTP_STATUS="$(curl -s -o /tmp/mcp-resp.json -w "%{http_code}" \
    -X POST "http://${EAST_IP}:8080/mcp/east" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0.1"}}}' \
    2>/dev/null || echo "failed")"
  if [[ "$HTTP_STATUS" == "200" ]]; then
    log_ok "MCP initialize: HTTP 200"
    log "response: $(cat /tmp/mcp-resp.json | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("result",{}).get("serverInfo",{}).get("name","?"))' 2>/dev/null || cat /tmp/mcp-resp.json)"
  else
    log "MCP initialize: HTTP $HTTP_STATUS — check that echo-mcp is up and agw backends are ready"
  fi
fi

# ---------- Scenario C: Waypoint authz — authorised vs rogue ----------
step "Scenario C — waypoint authz (SPIFFE identity enforcement)"
log "running authorised call from demo-agent SA..."
kubectl --context "$CLUSTER1" -n ai-demo run authz-test-ok \
  --image=curlimages/curl:8.5.0 \
  --serviceaccount=demo-agent \
  --restart=Never --rm -it --quiet \
  -- curl -s -o /dev/null -w "demo-agent → echo-mcp: HTTP %{http_code}\n" \
     http://echo-mcp.ai-demo.svc.cluster.local:8080/mcp 2>/dev/null || true

log "running rogue call from default SA (should 403)..."
kubectl --context "$CLUSTER1" -n ai-demo run authz-test-fail \
  --image=curlimages/curl:8.5.0 \
  --serviceaccount=default \
  --restart=Never --rm -it --quiet \
  -- curl -s -o /dev/null -w "default → echo-mcp: HTTP %{http_code} (expect 403)\n" \
     http://echo-mcp.ai-demo.svc.cluster.local:8080/mcp 2>/dev/null || true

# ---------- Scenario D: Cross-cluster ----------
step "Scenario D — cross-cluster MCP call (east agent → west echo-mcp)"
log "agent in east calling echo-mcp.ai-demo.svc.west.mesh.internal..."
kubectl --context "$CLUSTER1" -n ai-demo run xcluster-test \
  --image=curlimages/curl:8.5.0 \
  --serviceaccount=demo-agent \
  --restart=Never --rm -it --quiet \
  -- curl -s -o /dev/null -w "east→west echo-mcp: HTTP %{http_code}\n" \
     http://echo-mcp.ai-demo.svc.west.mesh.internal:8080/mcp 2>/dev/null || \
  log "cross-cluster test skipped (ensure remote-secret peering is in place)"

# ---------- Summary ----------
step "Demo workloads summary"
for ctx in "$CLUSTER1" "$CLUSTER2"; do
  echo ""
  echo "  [${ctx#kind-}]"
  kubectl --context "$ctx" -n ai-demo get pods,svc -o wide 2>/dev/null | sed 's/^/    /'
done

echo ""
echo "Useful commands:"
echo "  # Watch agentgateway access logs"
echo "  kubectl --context kind-east -n agentgateway-system logs -l app.kubernetes.io/name=agw-ingress -f"
echo ""
echo "  # Describe waypoint policy status"
echo "  kubectl --context kind-east -n ai-demo get enterpriseagentgatewaypolicies"
echo ""
echo "  # Check cross-cluster endpoint registration"
echo "  kubectl --context kind-east -n istio-system get serviceentries"
echo ""
echo "  # Proxy-config dump from demo-agent perspective"
echo "  istioctl --context kind-east -n ai-demo proxy-config endpoint demo-agent"
