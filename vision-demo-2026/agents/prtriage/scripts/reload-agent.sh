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
DEP="${1:-${DEP:-prtriagejava}}"
# 2>/dev/null: the kagent controller writes duplicate env vars, so kubectl warns
# about "hides previous definition of KAGENT_NAMESPACE" on every restart. It is
# harmless and it is not something to have on a projector.
$K -n "$NS" rollout restart "deploy/$DEP" >/dev/null 2>/dev/null
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
# Assert the pod is on the image that was just pushed, not a node-cached older one.
# A stale image is the worst failure here because everything looks fine and the agent
# is running last build's instructions.
WANT="$(docker image inspect "${IMAGE:-localhost:5001/prtriage-java:latest}" \
        --format '{{.Id}}' 2>/dev/null | sed 's/^sha256://')"
GOT="$($K -n "$NS" get "$POD" -o jsonpath='{.status.containerStatuses[0].imageID}' \
       | sed 's/.*sha256://')"
if [ -n "$WANT" ] && [ -n "$GOT" ] && [ "$WANT" != "$GOT" ]; then
  echo "✗ $DEP is running a different image from the one built locally"
  echo "    built:   sha256:$WANT"
  echo "    running: sha256:$GOT"
  echo "    the node cached this tag. Run: make -C agents/prtriage/java-agent push"
  exit 1
fi
echo "✓ $DEP reloaded, gateway toolMode = ${MODE:-Standard}"
# Name the image it came back on. It is the same digest `make deploy` printed, and
# saying so is the whole point: the change was to the gateway, not to the agent.
printf '  running image  %s\n' \
  "$($K -n "$NS" get "$POD" -o jsonpath='{.status.containerStatuses[0].imageID}')"
