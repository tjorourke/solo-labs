#!/usr/bin/env bash
# Live demo, one step at a time. Press Enter to run each command. Assumes ./scripts/quick.sh up has run,
# the port-forwards are up (./scripts/quick.sh port-forward) and Codex has the lab entries (codex-config.sh apply).
# Re-runnable: it only reads, plus re-applies the same Deployment in step 2.
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh
export OIDC_ISSUER=$KEYCLOAK_ISSUER

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
run()  { printf '\n\033[36m$ %s\033[0m' "$*"; read -r _; eval "$@"; }
wait_for_me() { printf '\n\033[2m%s (Enter to carry on)\033[0m' "$*"; read -r _; }

say '1. Four MCP servers run outside the cluster: health and finance in cloud-a, telco and compute in cloud-b.'
run './scripts/quick.sh servers-status'

say '2. The platform team catalogues them in agentregistry by URL, then deploys them through the gateway runtime.'
run "cat registry/mcpservers.yaml"
run "arctl get mcp"
run "arctl apply -f - < registry/deployments.yaml"

say '3. The registry wrote the gateway config itself: two backends per server and a child route.'
run "kubectl --context $CTX -n agentregistry-system get enterpriseagentgatewaybackends,httproutes"
run "arctl get deployments -o yaml | grep -A2 'runtime:'"

say '4. Nothing gets through without a Keycloak sign-in.'
run "curl -s -o /dev/null -w '%{http_code}\n' -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d '{}' $GW_LOCAL/registry/compute"
run "curl -s $GW_LOCAL/.well-known/oauth-protected-resource/registry/compute | jq"

say '5. Developer side. Codex discovers what exists through the read-only registry MCP.'
run 'eval "$(./scripts/mint-token.sh)"; echo "LAB_AR_TOKEN set for dev-user"'
wait_for_me 'In a new terminal with LAB_AR_TOKEN exported, run: codex   then ask: "Which MCP servers can I use through the gateway, and at what URLs?"'

say '6. Sign in to compute-inventory through Keycloak (dev-user / password).'
wait_for_me 'In a terminal run: codex mcp login lab-compute   A browser opens on Keycloak. Sign in as dev-user.'
run "codex mcp list"

say '7. Call tools. restart_vm is not in the list for a developer.'
wait_for_me 'In codex ask: "Which compute-inventory instances are stopped in eu-london-1?" then "Restart checkout-api-02."'

say '8. Same thing from curl, so the 400 is visible.'
run 'DEV=$(mint_token dev-user); S=$(mcp_init $GW_LOCAL/registry/compute $DEV); mcp_rpc $GW_LOCAL/registry/compute $DEV $S '"'"'{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"restart_vm","arguments":{"name":"checkout-api-02"}}}'"'"' | tail -3'

say '9. The registry has a second, read-only MCP server on :31313 that lists the whole catalogue, not only servers.'
run "codex mcp list"
wait_for_me 'With LAB_AR_TOKEN still exported, run: codex   then ask: "Using lab-registry, list every MCP server, agent, skill, prompt, runtime, model and plugin registered in AgentRegistry."'

say 'Done. If sign-in failed in step 6: ./scripts/codex-config.sh bearer, eval "$(./scripts/mint-token.sh)", restart codex.'
