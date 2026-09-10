#!/usr/bin/env bash
# set-mode.sh <Standard|Search|Code|CodeSearch> — change the gateway's tool surface.
#
# Patches BOTH backends, because the ingress one is what mcp.sh talks to from the laptop
# and the kagent one is what the agents reach through the waypoint. Letting them drift
# means showing one thing and measuring another.
#
# Then waits for the gateway to actually serve it, and restarts the agents, which read
# their MCP tool list once at startup.
set -euo pipefail
MODE="${1:?usage: set-mode.sh <Standard|Search|Code|CodeSearch>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K="kubectl --context ${CTX:-kind-mesh1}"
for ns in agentgateway-system kagent; do
  $K -n "$ns" patch enterpriseagentgatewaybackend github-mcp \
    --type=merge -p "{\"spec\":{\"entMcp\":{\"toolMode\":\"$MODE\"}}}" >/dev/null
done
echo "  toolMode = $MODE on both backends"
"$HERE/wait-for-mode.sh" "$MODE"
for dep in prtriagejava releasejava; do
  $K -n kagent get deploy/$dep >/dev/null 2>&1 || continue
  DEP=$dep "$HERE/reload-agent.sh" >/dev/null && echo "  $dep re-listed its tools"
done
