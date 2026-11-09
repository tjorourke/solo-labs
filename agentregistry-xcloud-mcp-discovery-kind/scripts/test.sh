#!/usr/bin/env bash
# Checks the lab from the laptop side. Reads state back; never trusts an exit code alone.
# Starts port-forwards only if they are not already up, and stops only the ones it started.
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh
fail=0
ok()  { echo "PASS  $*"; }
bad() { echo "FAIL  $*"; fail=1; }

started=0
if ! curl -s -o /dev/null --max-time 3 "$GW_LOCAL/registry/cloud-a"; then start_port_forwards; started=1; fi

export OIDC_ISSUER=$KEYCLOAK_ISSUER
deps=$(arctl get deployments -o yaml 2>/dev/null)
for d in cloud-a cloud-b; do
  grep -q "/registry/$d" <<<"$deps" && ok "registry reports an endpoint for /registry/$d" || bad "no endpoint for /registry/$d"
done
grep -q DeployedViaAgentgateway <<<"$deps" && ok 'Deployment Ready reason DeployedViaAgentgateway' || bad 'no DeployedViaAgentgateway condition'

n=$(kubectl --context "$CTX" -n agentregistry-system get enterpriseagentgatewaybackends --no-headers 2>/dev/null | wc -l | tr -d ' ')
[[ $n -ge 4 ]] && ok "registry wrote $n EnterpriseAgentgatewayBackends" || bad "expected 4 registry backends, found $n"
kubectl --context "$CTX" -n agentgateway-system get enterpriseagentgatewaypolicy registry-mcp-auth \
  -o jsonpath='{.status.ancestors[*].conditions[?(@.type=="Accepted")].status}' | grep -q True \
  && ok 'registry-mcp-auth policy Accepted' || bad 'registry-mcp-auth policy not Accepted'

code=$(curl -s -o /dev/null -w '%{http_code}' "${mcp_headers[@]}" -d '{}' "$GW_LOCAL/registry/cloud-a")
[[ $code == 401 ]] && ok 'no token on /registry/cloud-a gives 401' || bad "no token gave $code, expected 401"

prm=$(curl -s "$GW_LOCAL/.well-known/oauth-protected-resource/registry/cloud-a")
jq -e --arg iss "$KEYCLOAK_ISSUER" '.authorization_servers | index($iss)' <<<"$prm" >/dev/null \
  && ok "PRM points Codex at $KEYCLOAK_ISSUER" || bad "PRM missing or wrong: $prm"
echo "      PRM resource: $(jq -r .resource <<<"$prm" 2>/dev/null)"

DEV=$(mint_token dev-user); ADMIN=$(mint_token admin-user)
[[ $DEV == ey* ]] && ok 'minted a dev-user token from Keycloak' || bad 'could not mint dev-user token'

s=$(mcp_init "$GW_LOCAL/registry/cloud-a" "$DEV")
[[ -n $s ]] && ok 'dev-user opened an MCP session on cloud-a' || bad 'no MCP session for dev-user'
tools=$(mcp_rpc "$GW_LOCAL/registry/cloud-a" "$DEV" "$s" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')
grep -q get_instance <<<"$tools" && ok 'dev-user sees get_instance' || bad 'dev-user cannot see get_instance'
grep -q restart_instance <<<"$tools" && bad 'dev-user can see restart_instance' || ok 'restart_instance hidden from dev-user'
r=$(mcp_rpc "$GW_LOCAL/registry/cloud-a" "$DEV" "$s" '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"restart_instance","arguments":{"name":"web-01"}}}')
[[ $(tail -n1 <<<"$r") == 400 ]] && ok 'restart_instance by name returns 400 (unknown resource)' || bad "restart_instance returned $(tail -n1 <<<"$r")"
r=$(mcp_rpc "$GW_LOCAL/registry/cloud-a" "$DEV" "$s" '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_instance","arguments":{"name":"web-01"}}}')
grep -q eu-west <<<"$r" && ok 'get_instance web-01 answered through the gateway' || bad 'get_instance failed'

s=$(mcp_init "$GW_LOCAL/registry/cloud-a" "$ADMIN")
mcp_rpc "$GW_LOCAL/registry/cloud-a" "$ADMIN" "$s" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | grep -q restart_instance \
  && ok 'admin-user still sees restart_instance' || bad 'admin-user cannot see restart_instance'

s=$(mcp_init "$GW_LOCAL/registry/cloud-b" "$DEV")
mcp_rpc "$GW_LOCAL/registry/cloud-b" "$DEV" "$s" '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"monthly_spend","arguments":{"month":"2026-10"}}}' | grep -q 43877 \
  && ok 'cloud-b monthly_spend answered through the gateway' || bad 'cloud-b call failed'

s=$(mcp_init "$AR_MCP_LOCAL" "$DEV")
mcp_rpc "$AR_MCP_LOCAL" "$DEV" "$s" '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_deployments","arguments":{}}}' | grep -q cloud-a \
  && ok 'registry MCP list_deployments shows cloud-a to dev-user' || bad 'registry MCP list_deployments did not show cloud-a'

[[ $started == 1 ]] && stop_port_forwards
exit $fail
