#!/usr/bin/env bash
# Stop the agentgateway controller melting the mesh1 control plane.
#
# THE PROBLEM
#
# AgentRegistry Enterprise v2026.8.0 mirrors every remote MCPServer registration
# (an MCPServer with spec.remote.url) into three agentgateway objects in the AR
# install namespace:
#
#   gw-rt-mcpserver-<ns>-<name>-<hash>    HTTPRoute
#   gw-be-mcpserver-<ns>-<name>-<hash>    EnterpriseAgentgatewayBackend (spec.mcp)
#   gw-pol-mcpserver-<ns>-<name>-authz-…  AgentgatewayPolicy (backend.mcp.authorization)
#
# With the enterprise-agentgateway controller v2026.8.2, that combination sends
# the controller into a status-write loop on the backend: ~190 status PUTs per
# second per backend, content byte-identical every time. It is invisible in
# object counts and barely moves resourceVersion, but every write is a full
# apiserver admission cycle. Measured on kind-mesh1 2026-09-21:
#
#   two backends  ->  ~250 status PUTs/sec, kube-apiserver 100% CPU,
#                     etcd 27%, node load ~10, control-plane container 273%,
#                     OrbStack Helper 663% on the Mac
#
# It is not cosmetic. The saturated apiserver stops servicing leader-election
# lease renewals, so components self-terminate: ext-auth-service died 13 times
# with "lost leadership, quitting app", plus its waypoint (7), gloo-mesh-agent
# (4) and kagent-controller (3).
#
# THE FIX
#
# Rewriting the generated backend from spec.mcp to spec.entMcp (the Enterprise
# field, same targets) stops it dead: 0 PUTs/sec, control plane back to ~5%.
# The CRD allows exactly one of [ai static dynamicForwardProxy mcp aws a2a
# entMcp], so this is a swap, not an addition.
#
# A plain hand-written EnterpriseAgentgatewayBackend with spec.mcp does NOT
# churn - verified with a throwaway object. The trigger needs AR's full
# generated set, so no lab manifest in this repo is affected.
#
# WHY THIS SCRIPT EXISTS
#
# AR re-applies spec.mcp, so the churn comes back for every newly registered
# MCP server. AR's apply then fails validation against entMcp and it logs
# "reconcile failed; requeueing" every ~40s, which is cheap and harmless
# compared to 250 writes/sec. Run this before a demo, and again after
# registering a new MCP server.
#
#   ./fix-ar-backend-churn.sh          # convert any spec.mcp backends
#   ./fix-ar-backend-churn.sh --watch  # keep converting as AR creates them
#
# Remove it once the controller backs off properly, or once AR emits entMcp.
set -euo pipefail

CTX="${CTX:-kind-mesh1}"
NS="${NS:-agentregistry-system}"

convert_once() {
  local names
  names=$(kubectl --context "$CTX" get enterpriseagentgatewaybackend -n "$NS" -o json 2>/dev/null \
    | python3 -c "
import json, sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
for i in d.get('items', []):
    if 'mcp' in (i.get('spec') or {}):
        print(i['metadata']['name'])
")
  [ -z "$names" ] && return 0

  for n in $names; do
    # Carry the existing targets over verbatim; only the field name changes.
    patch=$(kubectl --context "$CTX" get enterpriseagentgatewaybackend "$n" -n "$NS" -o json 2>/dev/null \
      | python3 -c "
import json, sys
spec = json.load(sys.stdin)['spec']
ent = {'failureMode': 'FailClosed', 'sessionRouting': 'Stateful'}
ent.update({k: v for k, v in (spec.get('mcp') or {}).items()})
print(json.dumps({'spec': {'mcp': None, 'entMcp': ent}}))
")
    if kubectl --context "$CTX" patch enterpriseagentgatewaybackend "$n" -n "$NS" \
         --type=merge -p "$patch" >/dev/null 2>&1; then
      echo "  converted $n to spec.entMcp"
    else
      echo "  FAILED to convert $n" >&2
    fi
  done
}

rate() {
  local a b
  a=$(kubectl --context "$CTX" get --raw /metrics 2>/dev/null \
      | grep '^apiserver_request_total{' | grep 'subresource="status"' \
      | grep agentgateway | awk '{s+=$NF} END{print s+0}')
  sleep 10
  b=$(kubectl --context "$CTX" get --raw /metrics 2>/dev/null \
      | grep '^apiserver_request_total{' | grep 'subresource="status"' \
      | grep agentgateway | awk '{s+=$NF} END{print s+0}')
  echo $(( (b - a) / 10 ))
}

if [ "${1:-}" = "--watch" ]; then
  echo "watching $NS for AR-generated backends on spec.mcp (ctrl-c to stop)"
  while true; do
    convert_once
    sleep 20
  done
fi

echo "agentgateway status PUTs before: $(rate)/sec"
convert_once
sleep 20
echo "agentgateway status PUTs after:  $(rate)/sec  (want 0)"
