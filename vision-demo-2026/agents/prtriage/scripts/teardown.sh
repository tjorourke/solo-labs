#!/usr/bin/env bash
# teardown.sh — take this part off the cluster entirely.
#
# Destructive, so it asks first. In a terminal it prompts; anywhere without a terminal
# (a notebook cell, CI) it does nothing unless you pass --yes.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K="kubectl --context ${CTX:-kind-mesh1}"

cat <<MSG
This removes Part 8 from the cluster:
  the three agents and their deployments, the GitHub MCP catalogue entry and the skill,
  both policies, the waypoint, the backend, the published route, and the GitHub PAT Secret.
Standing it back up is ./agents/prtriage/scripts/setup.sh. The seeded pull requests are
not touched.
MSG

if [ "${1:-}" = "--yes" ]; then
  :
elif [ -t 0 ]; then
  printf 'Type teardown to continue: '
  read -r answer
  [ "$answer" = "teardown" ] || { echo "  left alone"; exit 1; }
else
  echo
  echo "Nothing removed. Re-run with --yes to confirm:"
  echo "  ./agents/prtriage/scripts/teardown.sh --yes"
  exit 1
fi
echo

for r in "deployment releasejava" "agent releasejava" \
         "deployment changelogjava" "agent changelogjava" \
         "deployment prtriagejava" "agent prtriagejava" \
         "mcpserver github-mcp" "skill release-report"; do
  arctl delete $r >/dev/null 2>&1 && echo "  removed $r from the registry"
done
$K -n agentgateway-system delete enterpriseagentgatewaypolicy github-mcp-ingress-auth --ignore-not-found
$K -n kagent delete networkpolicy agents-egress-through-the-gateway --ignore-not-found
$K delete -f "$HERE/../yaml/90-model-egress.yaml" --ignore-not-found
$K -n kagent delete enterpriseagentgatewaypolicy github-per-agent --ignore-not-found
$K -n agentgateway-system delete enterpriseagentgatewaypolicy github-readonly --ignore-not-found
$K delete -f "$HERE/../yaml/15-github-waypoint.yaml" --ignore-not-found
$K -n agentgateway-system delete enterpriseagentgatewaybackend github-mcp --ignore-not-found
$K -n agentgateway-system delete httproute github-mcp --ignore-not-found
for ns in agentgateway-system kagent; do
  $K -n $ns delete secret github-mcp-pat --ignore-not-found
done
echo "  ✓ Part 8 removed"
