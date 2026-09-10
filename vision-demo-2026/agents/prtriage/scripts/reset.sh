#!/usr/bin/env bash
# reset.sh — back to the state preflight calls ready: Standard, no policy, one agent.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K="kubectl --context ${CTX:-kind-mesh1}"
$K -n kagent delete enterpriseagentgatewaypolicy github-per-agent --ignore-not-found
$K -n agentgateway-system delete enterpriseagentgatewaypolicy github-readonly --ignore-not-found
arctl delete deployment releasejava >/dev/null 2>&1 || true
arctl delete agent releasejava >/dev/null 2>&1 || true
$K -n kagent delete deploy releasejava --ignore-not-found
"$HERE/set-mode.sh" Standard
echo "  ✓ reset"
