#!/usr/bin/env bash
# reset.sh — back to the state preflight calls ready: Standard, no policy, one agent.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K="kubectl --context ${CTX:-kind-mesh1}"
# Re-APPLIED, not removed. It is cluster setup, so the state to return to between runs
# is with it in place.
$K apply -f "$HERE/../yaml/70-identity-policy.yaml" >/dev/null
# Step 2 authenticates the published listener, so a reset has to re-open it or there is
# nothing for that beat to do.
$K -n agentgateway-system delete enterpriseagentgatewaypolicy github-mcp-ingress-auth --ignore-not-found >/dev/null
# and un-publish the route, so step 1 has something to publish
$K -n agentgateway-system delete httproute github-mcp --ignore-not-found >/dev/null
$K -n agentgateway-system delete enterpriseagentgatewaypolicy github-readonly --ignore-not-found
arctl delete deployment releasejava >/dev/null 2>&1 || true
arctl delete agent releasejava >/dev/null 2>&1 || true
$K -n kagent delete deploy releasejava --ignore-not-found
# changelogjava deliberately survives a reset. It is part of setup, not a beat: the
# story is that another team's agent has been running here all along.
"$HERE/set-mode.sh" Standard
echo "  ✓ reset"
