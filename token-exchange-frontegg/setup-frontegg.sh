#!/usr/bin/env bash
# Automated Frontegg IdP provisioning for the token-exchange demo.
# Creates a tenant + the alice/bob/carol personas with roles, sets the env to
# email+password. Credentials are sourced from the gitignored secrets file, never
# hardcoded here:  source /Users/.../secrets/frontegg.keys  (FE_CLIENT/FE_SECRET/FE_HOST...)
#
# Discovered from the demo account: host app-0nieh7hz8iun.frontegg.com,
# issuer https://app-0nieh7hz8iun.frontegg.com, jwks .../.well-known/jwks.json,
# and grant_types_supported INCLUDES urn:ietf:params:oauth:grant-type:token-exchange.
set -euo pipefail
: "${FE_CLIENT:?source the frontegg.keys secrets file first}"
: "${FE_SECRET:?}"; : "${FE_VENDOR_API:=https://api.frontegg.com}"
TENANT="${TENANT:-solo-demo}"

vtok() { curl -s -X POST "$FE_VENDOR_API/auth/vendor/" -H 'Content-Type: application/json' \
  -d "{\"clientId\":\"$FE_CLIENT\",\"secret\":\"$FE_SECRET\"}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])'; }
VTOK=$(vtok)
auth=(-H "Authorization: Bearer $VTOK")

echo "== set authStrategy = EmailAndPassword =="
curl -s -X POST "$FE_VENDOR_API/identity/resources/configurations/v1" "${auth[@]}" \
  -H 'Content-Type: application/json' -d '{"authStrategy":"EmailAndPassword"}' >/dev/null

echo "== create tenant $TENANT =="
curl -s -X POST "$FE_VENDOR_API/tenants/resources/tenants/v1" "${auth[@]}" \
  -H 'Content-Type: application/json' -d "{\"tenantId\":\"$TENANT\",\"name\":\"Solo Demo\"}" >/dev/null || true

# role ids
ROLES=$(curl -s "$FE_VENDOR_API/identity/resources/roles/v2" "${auth[@]}" -H "frontegg-tenant-id: $TENANT")
ADMIN=$(echo "$ROLES" | python3 -c 'import sys,json; d=json.load(sys.stdin); items=d.get("items",d); print([r["id"] for r in items if r["key"]=="Admin"][0])')
RO=$(echo "$ROLES" | python3 -c 'import sys,json; d=json.load(sys.stdin); items=d.get("items",d); print([r["id"] for r in items if r["key"]=="ReadOnly"][0])')

# migrate (sets password directly) then verify
mkuser() { # email name
  curl -s -X POST "$FE_VENDOR_API/identity/resources/migrations/v1/local" "${auth[@]}" -H 'Content-Type: application/json' \
    -d "{\"email\":\"$1\",\"password\":\"Passw0rd!23\",\"name\":\"$2\",\"verified\":true,\"tenantId\":\"$TENANT\"}" >/dev/null || true
}
echo "== create personas =="
mkuser "alice@solo.io" "Alice"; mkuser "bob@solo.io" "Bob"; mkuser "carol@solo.io" "Carol"
for id in $(curl -s "$FE_VENDOR_API/identity/resources/users/v3" "${auth[@]}" -H "frontegg-tenant-id: $TENANT" \
    | python3 -c 'import sys,json; [print(u["id"]) for u in json.load(sys.stdin)["items"]]'); do
  curl -s -X POST "$FE_VENDOR_API/identity/resources/users/v1/$id/verify" "${auth[@]}" >/dev/null || true
done

echo "== users =="
curl -s "$FE_VENDOR_API/identity/resources/users/v3" "${auth[@]}" -H "frontegg-tenant-id: $TENANT" \
  | python3 -c 'import sys,json; [print(" ",u["email"],"verified:",u.get("verified"),"activatedForTenant:",u.get("activatedForTenant")) for u in json.load(sys.stdin)["items"]]'

cat <<'NOTE'

== LAST MILE (manual, ~1 click) ==
Users are created + verified but activatedForTenant=false, and this hosted-login env
gates the API password login (ER-01182) until a user is activated. The vendor API
does not expose an activation toggle. To finish:
  - In the Frontegg portal, open the user and Activate (or have them complete the
    hosted-login flow once), OR enable the password login method for the environment.
Then mint a token and run the gateway exchange:
  curl -s -X POST "https://$FE_HOST/identity/resources/auth/v1/user" \
    -H 'Content-Type: application/json' -d '{"email":"alice@solo.io","password":"Passw0rd!23"}'
  # take .accessToken -> POST to the STS :7777/oauth2/token with subject_token_type=...jwt
NOTE
