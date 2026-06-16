#!/usr/bin/env bash
# Token-exchange E2E on kind-a2a-obo (enterprise-agentgateway v2.3.3, Keycloak 26.3.5).
# Proves both models: (A) Keycloak-native RFC 8693 swap, (B) the agentgateway STS swap.
# Re-run end to end; it is idempotent on the Keycloak side except client creation.
set -euo pipefail
CTX=kind-a2a-obo
KC="kubectl --context $CTX -n keycloak exec -i keycloak-0 -- /opt/keycloak/bin/kcadm.sh"

echo "== ensure chart-registry auth (for any helm step) =="
gcloud auth print-access-token | helm registry login -u oauth2accesstoken --password-stdin us-docker.pkg.dev >/dev/null

echo "== port-forwards =="
kubectl --context $CTX -n keycloak port-forward svc/keycloak 8088:80 >/tmp/pfkc.log 2>&1 & PFK=$!
kubectl --context $CTX -n agentgateway-system port-forward deploy/enterprise-agentgateway 7777:7777 >/tmp/pf77.log 2>&1 & PF7=$!
trap 'kill $PFK $PF7 2>/dev/null || true' EXIT
sleep 3
KB=http://localhost:8088/realms/solo/protocol/openid-connect/token

echo "== 1. mint alice's user token (mcp-client, ROPC) =="
SUBJ=$(curl -s -d 'grant_type=password&client_id=mcp-client&username=alice&password=password&scope=openid' "$KB" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')

echo "== 2. MODEL A — Keycloak-native RFC 8693 swap =="
# Needs: agentgateway-exchange client (standard.token.exchange.enabled), audience mappers.
EXSECRET=$($KC config credentials --server http://localhost:8080 --realm master --user admin --password admin >/dev/null 2>&1; \
  exid=$($KC get clients -r solo -q clientId=agentgateway-exchange --fields id 2>/dev/null | grep -oE '"id"[^,]+' | head -1 | cut -d'"' -f4); \
  $KC get clients/$exid/client-secret -r solo --fields value 2>/dev/null | grep value | cut -d'"' -f4)
curl -s -u "agentgateway-exchange:${EXSECRET}" \
  -d 'grant_type=urn:ietf:params:oauth:grant-type:token-exchange' \
  --data-urlencode "subject_token=$SUBJ" \
  -d 'subject_token_type=urn:ietf:params:oauth:token-type:access_token' \
  -d 'requested_token_type=urn:ietf:params:oauth:token-type:access_token' \
  -d 'audience=mcp-downstream' "$KB" \
  | python3 -c 'import sys,json,base64; d=json.load(sys.stdin); t=d.get("access_token");
p=t.split(".")[1]+"=="; c=json.loads(base64.urlsafe_b64decode(p)); print("  Keycloak-issued:",{k:c.get(k) for k in ("iss","sub","aud","azp")})' 2>/dev/null \
  || echo "  (model A error — see raw response)"

echo "== 3. MODEL B — agentgateway STS swap (the product mechanism) =="
# Needs ONLY: STS enabled + subjectValidator pointed at Keycloak JWKS. No Keycloak exchange client.
curl -s http://localhost:7777/oauth2/token \
  -d 'grant_type=urn:ietf:params:oauth:grant-type:token-exchange' \
  --data-urlencode "subject_token=$SUBJ" \
  -d 'subject_token_type=urn:ietf:params:oauth:token-type:jwt' \
  -d 'requested_token_type=urn:ietf:params:oauth:token-type:jwt' \
  -d 'audience=mcp-downstream' \
  | python3 -c 'import sys,json,base64; d=json.load(sys.stdin); t=d["access_token"];
p=t.split(".")[1]+"=="; c=json.loads(base64.urlsafe_b64decode(p)); print("  gateway-issued:",{k:c.get(k) for k in ("iss","sub","aud","scope")})'
echo "== done =="
