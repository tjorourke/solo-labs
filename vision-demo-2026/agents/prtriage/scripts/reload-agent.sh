#!/usr/bin/env bash
# reload-agent.sh — make the agent pick up a toolMode change, and wait properly.
#
# Two things this exists for. The agent lists its MCP tools ONCE at startup, so a
# toolMode flip on the gateway is invisible until it re-lists. And a plain
# `rollout status` returns while the old pod is still terminating, so the next
# `kubectl exec` can land on it and die with "cannot exec in a deleted state" -
# we wait for exactly one Running pod instead.
set -euo pipefail
K="kubectl --context ${CTX:-kind-mesh1}"
NS="${NS:-kagent}"
DEP="${DEP:-prtriage}"
$K -n "$NS" rollout restart "deploy/$DEP" >/dev/null
$K -n "$NS" rollout status "deploy/$DEP" --timeout=240s >/dev/null
for _ in $(seq 1 90); do
  n=$($K -n "$NS" get pods -l "app.kubernetes.io/name=$DEP" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  r=$($K -n "$NS" get pods -l "app.kubernetes.io/name=$DEP" --no-headers 2>/dev/null | grep -c Running || true)
  [ "$n" = "1" ] && [ "$r" = "1" ] && break
  sleep 2
done
sleep 4   # the ADK process lists its MCP tools a moment after the port opens
MODE=$($K -n agentgateway-system get enterpriseagentgatewaybackend github-mcp \
       -o jsonpath='{.spec.entMcp.toolMode}' 2>/dev/null || echo "?")
echo "✓ $DEP reloaded, gateway toolMode = ${MODE:-Standard}"
