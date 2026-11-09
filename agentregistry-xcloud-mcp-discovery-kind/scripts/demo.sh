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

say '1. Two MCP servers run outside the cluster. Think of them as one in each cloud.'
run "docker ps --filter name=ext-mcp --format 'table {{.Names}}\t{{.Status}}'"

say '2. The platform team catalogues them in agentregistry by URL, then deploys them through the gateway runtime.'
run "cat registry/mcpservers.yaml"
run "arctl get mcp"
run "arctl apply -f - < registry/deployments.yaml"

say '3. The registry wrote the gateway config itself: two backends per server and a child route.'
run "kubectl --context $CTX -n agentregistry-system get enterpriseagentgatewaybackends,httproutes"
run "arctl get deployments -o yaml | grep -A2 'runtime:'"

say '4. Nothing gets through without a Keycloak sign-in.'
run "curl -s -o /dev/null -w '%{http_code}\n' -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d '{}' $GW_LOCAL/registry/cloud-a"
run "curl -s $GW_LOCAL/.well-known/oauth-protected-resource/registry/cloud-a | jq"

say '5. Developer side. Codex discovers what exists through the read-only registry MCP.'
run 'eval "$(./scripts/mint-token.sh)"; echo "LAB_AR_TOKEN set for dev-user"'
wait_for_me 'In a new terminal with LAB_AR_TOKEN exported, run: codex   then ask: "Which MCP servers can I use through the gateway, and at what URLs?"'

say '6. Sign in to cloud-a through Keycloak (dev-user / password).'
wait_for_me 'In a terminal run: codex mcp login lab-cloud-a   A browser opens on Keycloak. Sign in as dev-user.'
run "codex mcp list"

say '7. Call tools. restart_instance is not in the list for a developer.'
wait_for_me 'In codex ask: "Which cloud-a instances are stopped in eu-west?" then "Restart web-02."'

say '8. Same thing from curl, so the 400 is visible.'
run 'DEV=$(mint_token dev-user); S=$(mcp_init $GW_LOCAL/registry/cloud-a $DEV); mcp_rpc $GW_LOCAL/registry/cloud-a $DEV $S '"'"'{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"restart_instance","arguments":{"name":"web-02"}}}'"'"' | tail -3'

say 'Done. If sign-in failed in step 6: ./scripts/codex-config.sh bearer, eval "$(./scripts/mint-token.sh)", restart codex.'
