#!/usr/bin/env bash
# Frontegg -> gateway STS token-exchange E2E (live, captured 2026-06-16).
# Mints a real Frontegg-issued token and exchanges it through the agentgateway STS.
# Prereq: STS validators pointed at Frontegg JWKS (frontegg-tokenexchange-values.yaml applied),
# and secrets sourced: source /Users/.../secrets/frontegg.keys
set -euo pipefail
: "${FE_CLIENT:?source frontegg.keys}"; : "${FE_HOST:?}"; : "${FE_VENDOR_API:=https://api.frontegg.com}"
TENANT="${TENANT:-solo-demo}"

VTOK=$(curl -s -X POST "$FE_VENDOR_API/auth/vendor/" -H 'Content-Type: application/json' \
  -d "{\"clientId\":\"$FE_CLIENT\",\"secret\":\"$FE_SECRET\"}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')

echo "== mint a real Frontegg-issued token (tenant M2M) =="
TR=$(curl -s -X POST "$FE_VENDOR_API/identity/resources/tenants/api-tokens/v1" \
  -H "Authorization: Bearer $VTOK" -H "frontegg-tenant-id: $TENANT" -H 'Content-Type: application/json' \
  -d '{"description":"agw-e2e","roleIds":[]}')
CID=$(echo "$TR" | python3 -c 'import sys,json;print(json.load(sys.stdin)["clientId"])')
CSEC=$(echo "$TR" | python3 -c 'import sys,json;print(json.load(sys.stdin)["secret"])')
FT=$(curl -s -X POST "https://$FE_HOST/identity/resources/auth/v1/api-token" \
  -H 'Content-Type: application/json' -d "{\"clientId\":\"$CID\",\"secret\":\"$CSEC\"}" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["accessToken"])')
echo "  subject token iss: $(echo "$FT" | cut -d. -f2 | python3 -c 'import sys,base64,json;s=sys.stdin.read()+"==";print(json.loads(base64.urlsafe_b64decode(s))["iss"])')"

echo "== exchange through the gateway STS =="
kubectl --context kind-a2a-obo -n agentgateway-system port-forward deploy/enterprise-agentgateway 7777:7777 >/tmp/pf77.log 2>&1 & PF=$!
trap 'kill $PF 2>/dev/null || true' EXIT
sleep 3
curl -s http://localhost:7777/oauth2/token \
  -d 'grant_type=urn:ietf:params:oauth:grant-type:token-exchange' \
  --data-urlencode "subject_token=$FT" \
  -d 'subject_token_type=urn:ietf:params:oauth:token-type:jwt' \
  -d 'requested_token_type=urn:ietf:params:oauth:token-type:jwt' \
  -d 'audience=mcp-downstream' \
  | python3 -c 'import sys,json,base64; d=json.load(sys.stdin); t=d["access_token"]; p=t.split(".")[1]+"=="; c=json.loads(base64.urlsafe_b64decode(p)); print("  gateway-minted:",{k:c.get(k) for k in ("iss","sub","aud")})'

# NOTE: sub here is the M2M client. For a human sub (alice), mint via the hosted
# login OAuth flow instead (this env disables the embedded password API, ER-01182),
# then POST that accessToken here unchanged.
