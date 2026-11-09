#!/usr/bin/env bash
# Checks the kagent step: STS, the /agent/* route and the cloud-ops agent. Run after scripts/up-kagent.sh.
# Reads state back. Starts port-forwards only if they are not up, and stops only the ones it started.
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh
fail=0
ok()  { echo "PASS  $*"; }
bad() { echo "FAIL  $*"; fail=1; }
k() { kubectl --context "$CTX" "$@"; }
started=0; started_kagent=0
if ! curl -s -o /dev/null --max-time 3 "$KC_LOCAL/realms/agentregistry"; then start_port_forwards; started=1; fi
if ! curl -s -o /dev/null --max-time 3 http://localhost:18083/health; then start_kagent_port_forwards; started_kagent=1; fi

k -n agentgateway-system get svc enterprise-agentgateway -o jsonpath='{.spec.ports[*].port}' | grep -qw 7777 \
  && ok 'STS listening on enterprise-agentgateway:7777' || bad 'STS port 7777 missing'
k -n agentgateway-system get enterpriseagentgatewaypolicy agent-mcp-auth \
  -o jsonpath='{.status.ancestors[*].conditions[?(@.type=="Accepted")].status}' | grep -q True \
  && ok 'agent-mcp-auth policy Accepted' || bad 'agent-mcp-auth policy not Accepted'
[[ $(k -n kagent get agent cloud-ops -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}') == True ]] \
  && ok 'cloud-ops agent Ready' || bad 'cloud-ops agent not Ready'
k -n kagent exec deploy/cloud-ops -- env 2>/dev/null | grep -q '^STS_WELL_KNOWN_URI=' \
  && ok 'STS_WELL_KNOWN_URI injected into the agent pod' || bad 'STS_WELL_KNOWN_URI missing from the agent pod'

# Exchange a dev-user token for a delegated token by hand, acting as the agent's service account.
k -n agentgateway-system port-forward svc/enterprise-agentgateway 17777:7777 --address=127.0.0.1 >/dev/null 2>&1 &
sts_pf=$!; sleep 3
# Retry: straight after a rebuild the port-forward can take a few seconds to connect (seen 9 Nov 2026).
sts=''
for _ in 1 2 3 4 5; do
sts=$(curl -s --max-time 10 http://127.0.0.1:17777/oauth2/token -d grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
  --data-urlencode "subject_token=$(mint_token dev-user)" -d subject_token_type=urn:ietf:params:oauth:token-type:jwt \
  --data-urlencode "actor_token=$(k -n kagent create token cloud-ops)" -d actor_token_type=urn:ietf:params:oauth:token-type:jwt \
  | jq -r '.access_token // empty' 2>/dev/null)
[[ -n $sts ]] && break; sleep 3
done
kill $sts_pf 2>/dev/null; wait $sts_pf 2>/dev/null
claims=$(cut -d. -f2 <<<"$sts" | tr '_-' '/+' | base64 -d 2>/dev/null)
grep -q '"developers"' <<<"$claims" && grep -q 'system:serviceaccount:kagent:cloud-ops' <<<"$claims" \
  && ok 'STS token carries the user Groups claim and act=cloud-ops' || bad 'STS token missing Groups or act'

url=$GW_LOCAL/agent/compute
code=$(curl -s -o /dev/null -w '%{http_code}' "${mcp_headers[@]}" -d '{}' "$url")
[[ $code == 401 ]] && ok "/agent/compute without a token: 401" || bad "/agent/compute without a token: $code"
code=$(curl -s -o /dev/null -w '%{http_code}' "${mcp_headers[@]}" -H "Authorization: Bearer $(mint_token dev-user)" -d '{}' "$url")
[[ $code == 401 ]] && ok "/agent/compute with a Keycloak token (not STS): 401" || bad "/agent/compute with a Keycloak token: $code"
s=$(mcp_init "$url" "${sts:-none}")
tl=$(mcp_rpc "$url" "${sts:-none}" "$s" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')
grep -q '"list_vms"' <<<"$tl" && ! grep -q '"restart_vm"' <<<"$tl" \
  && ok '/agent/compute with the STS token: dev-user sees list_vms, not restart_vm' || bad '/agent/compute tool list wrong for dev-user'

r=$(ask_agent dev-user 'Which VMs in eu-london-1 are stopped and what do they cost?')
[[ $(jq -r .result.status.state <<<"$r") == completed ]] && grep -q 'checkout-api-02' <<<"$r" && grep -q '960.45' <<<"$r" \
  && ok 'cloud-ops as dev-user: names checkout-api-02 and 960.45' || bad 'cloud-ops dev-user question did not answer'
r=$(ask_agent dev-user 'restart checkout-api-02')
! grep -q '"name":"restart_vm"' <<<"$r" && ok 'cloud-ops as dev-user: no restart_vm call' || bad 'dev-user reached restart_vm'
r=$(ask_agent admin-user 'restart checkout-api-02')
[[ $(jq -r .result.status.state <<<"$r") == input-required ]] && grep -q '"restart_vm"' <<<"$r" \
  && ok 'cloud-ops as admin-user: restart_vm waits for approval' || bad 'admin-user restart did not ask for approval'

[[ $started_kagent == 1 ]] && stop_kagent_port_forwards
[[ $started == 1 ]] && stop_port_forwards
exit $fail
