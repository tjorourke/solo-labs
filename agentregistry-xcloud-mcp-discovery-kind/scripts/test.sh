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
if ! curl -s -o /dev/null --max-time 3 "$GW_LOCAL/registry/compute"; then start_port_forwards; started=1; fi

for c in $MCP_NAMES; do
  lsof -nP -iTCP:"$(mcp_port "$c")" -sTCP:LISTEN >/dev/null 2>&1 \
    && ok "$c MCP server running on the laptop, port $(mcp_port "$c")" || bad "$c MCP server not listening on $(mcp_port "$c")"
done

export OIDC_ISSUER=$KEYCLOAK_ISSUER
# Log arctl in fresh as dev-user. A cached arctl session expires and then every registry check reads 401.
arctl user login --oidc-flow=password-credentials --oidc-client-id=ar-cli-password \
  --oidc-username=dev-user --oidc-password=password >/dev/null 2>&1 || bad 'arctl login as dev-user failed'
deps=$(arctl get deployments -o yaml 2>/dev/null)
for r in health finance telco compute; do
  grep -q "/registry/$r" <<<"$deps" && ok "registry reports an endpoint for /registry/$r" || bad "no endpoint for /registry/$r"
done
[[ $(grep -c DeployedViaAgentgateway <<<"$deps") -ge 4 ]] && ok 'four Deployments Ready with reason DeployedViaAgentgateway' || bad 'fewer than four DeployedViaAgentgateway conditions'

n=$(kubectl --context "$CTX" -n agentregistry-system get enterpriseagentgatewaybackends --no-headers 2>/dev/null | wc -l | tr -d ' ')
[[ $n -ge 4 ]] && ok "registry wrote $n EnterpriseAgentgatewayBackends" || bad "expected 4 registry backends, found $n"
p=$(kubectl --context "$CTX" -n agentgateway-system get enterpriseagentgatewaybackends --no-headers 2>/dev/null | grep -c -- '-prm ')
[[ $p -ge 4 ]] && ok "four sign-in metadata (PRM) backends in agentgateway-system" || bad "expected 4 PRM backends, found $p"
kubectl --context "$CTX" -n agentgateway-system get enterpriseagentgatewaypolicy registry-mcp-auth \
  -o jsonpath='{.status.ancestors[*].conditions[?(@.type=="Accepted")].status}' | grep -q True \
  && ok 'registry-mcp-auth policy Accepted' || bad 'registry-mcp-auth policy not Accepted'

DEV=$(mint_token dev-user); ADMIN=$(mint_token admin-user)
[[ $DEV == ey* && $ADMIN == ey* ]] && ok 'minted dev-user and admin-user tokens from Keycloak' || bad 'could not mint tokens'

# route  visible-tool  hidden-tool  safe-call-json  expected-text-in-answer
CASES=(
  'health|get_appointments|get_patient_record|{"name":"get_appointments","arguments":{"date":"2026-11-12"}}|HbA1c'
  'finance|list_transactions|issue_refund|{"name":"get_account_balance","arguments":{"account_id":"ACC-20-45-77-10293847"}}|18240.55'
  'telco|list_outages|reset_cell_site|{"name":"get_cell_site_status","arguments":{"site_id":"MAN-CS-0033"}}|S1 link lost'
  'compute|get_vm|restart_vm|{"name":"get_cost_by_vm","arguments":{"name":"ledger-batch-07"}}|6215.8'
)
for c in "${CASES[@]}"; do
  IFS='|' read -r r vis hid call want <<<"$c"
  url="$GW_LOCAL/registry/$r"
  code=$(curl -s -o /dev/null -w '%{http_code}' "${mcp_headers[@]}" -d '{}' "$url")
  [[ $code == 401 ]] && ok "$r: no token gives 401" || bad "$r: no token gave $code, expected 401"
  prm=$(curl -s "$GW_LOCAL/.well-known/oauth-protected-resource/registry/$r")
  jq -e --arg iss "$KEYCLOAK_ISSUER" --arg res "$url" '(.authorization_servers | index($iss)) and .resource == $res' <<<"$prm" >/dev/null \
    && ok "$r: PRM names Keycloak and resource $url" || bad "$r: PRM missing or wrong: $prm"
  s=$(mcp_init "$url" "$DEV")
  tools=$(mcp_rpc "$url" "$DEV" "$s" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')
  grep -q "\"$vis\"" <<<"$tools" && ok "$r: dev-user sees $vis" || bad "$r: dev-user cannot see $vis"
  grep -q "\"$hid\"" <<<"$tools" && bad "$r: dev-user can see $hid" || ok "$r: $hid hidden from dev-user"
  res=$(mcp_rpc "$url" "$DEV" "$s" "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"$hid\",\"arguments\":{}}}")
  [[ $(tail -n1 <<<"$res") == 400 ]] && ok "$r: $hid by name returns 400 for dev-user" || bad "$r: $hid by name returned $(tail -n1 <<<"$res")"
  res=$(mcp_rpc "$url" "$DEV" "$s" "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":$call}")
  grep -q "$want" <<<"$res" && ok "$r: dev-user call answered through the gateway" || bad "$r: dev-user call failed"
  s=$(mcp_init "$url" "$ADMIN")
  mcp_rpc "$url" "$ADMIN" "$s" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | grep -q "\"$hid\"" \
    && ok "$r: admin-user sees $hid" || bad "$r: admin-user cannot see $hid"
done

s=$(mcp_init "$AR_MCP_LOCAL" "$DEV")
depl=$(mcp_rpc "$AR_MCP_LOCAL" "$DEV" "$s" '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_deployments","arguments":{}}}')
for r in health finance telco compute; do
  grep -q "/registry/$r" <<<"$depl" && ok "registry MCP list_deployments shows /registry/$r to dev-user" || bad "registry MCP list_deployments missing /registry/$r"
done

[[ $started == 1 ]] && stop_port_forwards
exit $fail
