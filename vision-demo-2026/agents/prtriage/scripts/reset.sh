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

# prtriagejava is deployed by a beat in step 3, and teardown removes it, so a reset after a
# teardown would leave the cluster in a state preflight fails on. It is also the workload the
# mode check probes from, because tools are authorized per service account, so without it the
# check below times out and blames the gateway. Put it back when it is missing; a no-op
# between takes, which is the normal case.
if ! $K -n kagent get agent prtriagejava >/dev/null 2>&1; then
  echo "  prtriagejava is missing, deploying it (the same two commands step 3 runs)"
  arctl apply -f "$HERE/../java-agent/agent.yaml" >/dev/null
  arctl apply -f "$HERE/../yaml/60-java-deploy-kagent.yaml" >/dev/null
  for _ in $(seq 1 60); do
    $K -n kagent get agent prtriagejava >/dev/null 2>&1 && break
    sleep 2
  done
  $K -n kagent wait --for=condition=Ready agent/prtriagejava --timeout=240s >/dev/null \
    && echo "  ✓ prtriagejava ready" \
    || echo "  ✗ prtriagejava did not become ready; check kubectl -n kagent get agent prtriagejava"
fi

"$HERE/set-mode.sh" Standard
echo "  ✓ reset"
