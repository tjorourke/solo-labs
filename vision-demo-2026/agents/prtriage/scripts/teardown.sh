#!/usr/bin/env bash
# teardown.sh — take this part off the cluster entirely.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K="kubectl --context ${CTX:-kind-mesh1}"
for r in "deployment releasejava" "agent releasejava" \
         "deployment changelogjava" "agent changelogjava" \
         "deployment prtriagejava" "agent prtriagejava" \
         "mcpserver github-mcp" "skill release-report"; do
  arctl delete $r >/dev/null 2>&1 && echo "  removed $r from the registry"
done
$K -n kagent delete enterpriseagentgatewaypolicy github-per-agent --ignore-not-found
$K -n agentgateway-system delete enterpriseagentgatewaypolicy github-readonly --ignore-not-found
$K delete -f "$HERE/../yaml/15-github-waypoint.yaml" --ignore-not-found
$K -n agentgateway-system delete enterpriseagentgatewaybackend github-mcp --ignore-not-found
$K -n agentgateway-system delete httproute github-mcp --ignore-not-found
for ns in agentgateway-system kagent; do
  $K -n $ns delete secret github-mcp-pat --ignore-not-found
done
echo "  ✓ Part 8 removed"
