#!/usr/bin/env bash
# Enterprise AgentRegistry, in-cluster, as the one place agents are published from.
#
# AgentRegistry is the catalogue and the control point for what may run: an agent is
# registered here, and kagent deploys it FROM here. Nothing schedules an agent that did not
# come through the registry (the enforcement lands in a later step). It reuses the lab's
# existing Keycloak realm for identity, so there is one IdP, not two.
#
#   ./scripts/agentregistry.sh up        OIDC clients + AgentRegistry (bundled postgres)
#   ./scripts/agentregistry.sh status    what is running
#   ./scripts/agentregistry.sh down       remove it
set -euo pipefail

export AWS_PROFILE="${SOVEREIGN_AWS_PROFILE:?set SOVEREIGN_AWS_PROFILE to the sandbox SSO profile}"
REGION=eu-west-2
CLUSTER=uk-sovereign-ai
NS=agentregistry
KAGENT_NS=kagent
REALM=sovereign
AR_VERSION="${AR_VERSION:-2026.6.1}"
AR_CHART="oci://us-docker.pkg.dev/solo-public/agentregistry-enterprise/helm/agentregistry-enterprise"

ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
[ -n "$ACCOUNT" ] && [ "$ACCOUNT" != "None" ] || { echo "error: no AWS identity; check SOVEREIGN_AWS_PROFILE" >&2; exit 1; }
CTX="arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${CLUSTER}"
kc() { command kubectl --context "$CTX" "$@"; }
helm_() { command helm --kube-context "$CTX" "$@"; }

# Create (or reuse) an OIDC client in the sovereign realm and print its secret. Uses a
# stable Service port-forward and python3 JSON parsing (the pod port-forward and greedy
# sed both proved flaky).
kc_client() {
  local client="$1" public="$2" kcport=18099 kc_url="http://localhost:18099"
  kc -n keycloak port-forward svc/keycloak ${kcport}:80 >/tmp/ar-kc-pf.log 2>&1 &
  local pf=$!; trap "kill $pf 2>/dev/null || true" RETURN
  for _ in $(seq 1 30); do curl -sf "$kc_url/realms/${REALM}" >/dev/null 2>&1 && break; sleep 1; done
  local token; token="$(curl -s -X POST "$kc_url/realms/master/protocol/openid-connect/token" \
    -d 'grant_type=password&client_id=admin-cli&username=admin&password=admin' \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("access_token",""))')"
  [ -n "$token" ] || { echo "kc_client: no admin token" >&2; return 1; }
  local sa; sa="$([ "$public" = false ] && echo true || echo false)"
  local cid; cid="$(curl -s "$kc_url/admin/realms/${REALM}/clients?clientId=${client}" -H "Authorization: Bearer $token" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["id"] if d else "")')"
  if [ -z "$cid" ]; then
    curl -s -o /dev/null -X POST "$kc_url/admin/realms/${REALM}/clients" -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
      -d "{\"clientId\":\"${client}\",\"enabled\":true,\"protocol\":\"openid-connect\",\"publicClient\":${public},\"standardFlowEnabled\":true,\"directAccessGrantsEnabled\":true,\"serviceAccountsEnabled\":${sa},\"redirectUris\":[\"*\"],\"webOrigins\":[\"*\"]}"
    cid="$(curl -s "$kc_url/admin/realms/${REALM}/clients?clientId=${client}" -H "Authorization: Bearer $token" \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["id"] if d else "")')"
  fi
  curl -s "$kc_url/admin/realms/${REALM}/clients/${cid}/client-secret" -H "Authorization: Bearer $token" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("value",""))'
}

case "${1:-status}" in
  up)
    echo "==> OIDC clients ar-backend + ar-ui in realm '${REALM}'"
    AR_BACKEND_SECRET="$(kc_client ar-backend false)"
    kc_client ar-ui true >/dev/null
    [ -n "$AR_BACKEND_SECRET" ] || { echo "error: could not get ar-backend client secret" >&2; exit 1; }
    # the client AR uses to call kagent: reuse the kagent-enterprise client already in the realm.
    KAGENT_SECRET="$(kc -n "$KAGENT_NS" get secret kagent-enterprise-oidc-secret -o jsonpath='{.data.clientSecret}' 2>/dev/null | base64 -d)"

    kc create namespace "$NS" --dry-run=client -o yaml | kc apply -f - >/dev/null
    echo "==> AgentRegistry ${AR_VERSION} (bundled postgres, OIDC -> sovereign realm)"
    helm_ upgrade --install agentregistry "$AR_CHART" -n "$NS" --create-namespace --version "$AR_VERSION" \
      --set oidc.issuer="http://keycloak.keycloak.svc.cluster.local/realms/${REALM}" \
      --set oidc.clientId=ar-backend --set oidc.clientSecret="$AR_BACKEND_SECRET" \
      --set oidc.publicClientId=ar-ui \
      --set oidc.roleClaim=Groups --set oidc.superuserRole=admins \
      --set kagent.outboundAuth.oidc.clientId=kagent-enterprise \
      --set kagent.outboundAuth.oidc.clientSecret="${KAGENT_SECRET:-unset}" \
      --set database.postgres.type=bundled \
      --wait --timeout 8m
    echo "    installed. server:"
    kc -n "$NS" get deploy --no-headers 2>/dev/null | awk '{print "     ",$1,$2}'
    ;;

  status)
    kc -n "$NS" get pods --no-headers 2>/dev/null || echo "  not installed"
    ;;

  down)
    helm_ uninstall agentregistry -n "$NS" >/dev/null 2>&1 || true
    kc delete ns "$NS" --wait=false >/dev/null 2>&1 || true
    echo "removed"
    ;;

  *) echo "usage: $0 {up|status|down}"; exit 1 ;;
esac
