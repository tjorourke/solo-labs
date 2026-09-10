#!/usr/bin/env bash
# reload-agent.sh — make the agent pick up a toolMode change, and wait properly.
#
# Two things this exists for. The agent lists its MCP tools ONCE at startup, so a
# toolMode flip on the gateway is invisible until it re-lists. DEP overrides the target
# if you have another agent deployed. And a plain
# `rollout status` returns while the old pod is still terminating, so the next
# `kubectl exec` can land on it and die with "cannot exec in a deleted state" -
# we wait for exactly one Running pod instead.
set -euo pipefail
K="kubectl --context ${CTX:-kind-mesh1}"
NS="${NS:-kagent}"
DEP="${DEP:-prtriagejava}"
$K -n "$NS" rollout restart "deploy/$DEP" >/dev/null
$K -n "$NS" rollout status "deploy/$DEP" --timeout=240s >/dev/null
settled=""
for _ in $(seq 1 90); do
  n=$($K -n "$NS" get pods -l "app.kubernetes.io/name=$DEP" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  r=$($K -n "$NS" get pods -l "app.kubernetes.io/name=$DEP" --no-headers 2>/dev/null | grep -c Running || true)
  if [ "$n" = "1" ] && [ "$r" = "1" ]; then settled=yes; break; fi
  sleep 2
done
# Never claim a reload that did not happen. A stale pod answers with the OLD tool list,
# which looks like the gateway ignoring the toolMode change.
if [ -z "$settled" ]; then
  echo "✗ $DEP did not settle to a single Running pod after 180s"
  $K -n "$NS" get pods -l "app.kubernetes.io/name=$DEP"
  exit 1
fi
# The agent lists its MCP tools a moment after the port opens, so wait for the card
# rather than guessing with a sleep.
POD="$($K -n "$NS" get pods -l "app.kubernetes.io/name=$DEP" -o name | head -1)"
ready=""
for _ in $(seq 1 30); do
  if $K -n "$NS" get "$POD" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null | grep -q true; then
    ready=yes; break
  fi
  sleep 2
done
[ -n "$ready" ] || { echo "✗ $DEP pod never reported ready"; exit 1; }
MODE=$($K -n agentgateway-system get enterpriseagentgatewaybackend github-mcp \
       -o jsonpath='{.spec.entMcp.toolMode}' 2>/dev/null || echo "?")
echo "✓ $DEP reloaded, gateway toolMode = ${MODE:-Standard}"
