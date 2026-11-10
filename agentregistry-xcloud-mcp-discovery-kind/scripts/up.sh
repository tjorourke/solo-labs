#!/usr/bin/env bash
# Builds the xcloud-mcp lab end to end. Refuses an existing cluster. Never tears anything down.
set -euo pipefail
set +x
cd "$(dirname "$0")/.."
source scripts/lib.sh
source "${SECRETS_FILE:-$HOME/.solo/secrets.env}" >/dev/null 2>&1
# AGENTREGISTRY_LICENSE_KEY is the documented variable. If it is unset, fall back to SOLO_LICENSE_KEY.
# GLOO_* and MESH_* keys are never used. Only the variable name and a sha256 prefix are printed, never the value.
if [[ -n ${AGENTREGISTRY_LICENSE_KEY:-} ]]; then AR_LICENSE_SOURCE=AGENTREGISTRY_LICENSE_KEY
elif [[ -n ${SOLO_LICENSE_KEY:-} ]]; then AR_LICENSE_SOURCE=SOLO_LICENSE_KEY; AGENTREGISTRY_LICENSE_KEY=$SOLO_LICENSE_KEY
fi
: "${AGENTGATEWAY_LICENSE_KEY:?Set AGENTGATEWAY_LICENSE_KEY in the secrets file}"
# Needs a key that covers Solo Enterprise for agentregistry. Check the server log after install for the licence line.
: "${AGENTREGISTRY_LICENSE_KEY:?Set AGENTREGISTRY_LICENSE_KEY (or SOLO_LICENSE_KEY) in the secrets file}"
for bin in docker kind kubectl helm jq curl arctl python3 uv lsof; do
  command -v "$bin" >/dev/null || { echo "Missing $bin" >&2; exit 1; }
done
if kind get clusters | grep -qx "$CLUSTER"; then
  echo "Cluster $CLUSTER already exists. Refusing to replace it." >&2
  exit 1
fi

echo '== 1. kind cluster'
kind create cluster --config kind/cluster.yaml

echo '== 2. Four MCP servers outside the cluster, as plain processes on the laptop'
servers_up

echo '== 3. CoreDNS rewrite so pods resolve the Keycloak issuer host'
kubectl --context "$CTX" -n kube-system get configmap coredns -o json | python3 -c '
import json,sys
cm=json.load(sys.stdin); line=open("yaml/coredns-rewrite.txt").read().strip().splitlines()[-1]
cf=cm["data"]["Corefile"]
if line not in cf:
    cf=cf.replace("    kubernetes cluster.local", "    "+line+"\n    kubernetes cluster.local",1)
cm["data"]["Corefile"]=cf
for k in ("resourceVersion","uid","creationTimestamp","managedFields"): cm["metadata"].pop(k,None)
print(json.dumps(cm))' | kubectl --context "$CTX" apply -f -
kubectl --context "$CTX" -n kube-system rollout restart deployment/coredns
kubectl --context "$CTX" -n kube-system rollout status deployment/coredns --timeout=120s

echo '== 4. Keycloak'
kubectl --context "$CTX" apply -f yaml/keycloak.yaml
kubectl --context "$CTX" apply -f yaml/keycloak-realm.yaml
kubectl --context "$CTX" -n keycloak rollout status deploy/keycloak --timeout=300s
kubectl --context "$CTX" -n keycloak port-forward svc/keycloak 8180:8180 --address=127.0.0.1 >/dev/null 2>&1 &
KC_PF=$!
sleep 3
KEYCLOAK_TOKEN=$(curl -s -d client_id=admin-cli -d username=admin -d password=admin -d grant_type=password \
  "$KC_LOCAL/realms/master/protocol/openid-connect/token" | jq -r .access_token)
AR_BACKEND_ID=$(curl -s -H "Authorization: Bearer $KEYCLOAK_TOKEN" \
  "$KC_LOCAL/admin/realms/agentregistry/clients?clientId=ar-backend" | jq -r '.[0].id')
AR_BACKEND_SECRET=$(curl -s -H "Authorization: Bearer $KEYCLOAK_TOKEN" \
  "$KC_LOCAL/admin/realms/agentregistry/clients/$AR_BACKEND_ID/client-secret" | jq -r .value)
kill "$KC_PF" 2>/dev/null || true
[[ -n $AR_BACKEND_SECRET && $AR_BACKEND_SECRET != null ]] || { echo 'Could not read the ar-backend secret' >&2; exit 1; }

echo '== 5. Enterprise agentgateway'
kubectl --context "$CTX" apply -f "$GATEWAY_API_URL"
helm --kube-context "$CTX" upgrade -i enterprise-agentgateway-crds "$AGW_CHARTS/enterprise-agentgateway-crds" \
  --version "$AGW_VERSION" -n agentgateway-system --create-namespace --wait
printf '%s' "$AGENTGATEWAY_LICENSE_KEY" | kubectl --context "$CTX" -n agentgateway-system create secret generic \
  enterprise-agentgateway-license --from-file=enterprise-agentgateway-license-key=/dev/stdin --dry-run=client -o yaml | \
  kubectl --context "$CTX" apply -f -
helm --kube-context "$CTX" upgrade -i enterprise-agentgateway "$AGW_CHARTS/enterprise-agentgateway" \
  --version "$AGW_VERSION" -n agentgateway-system -f yaml/values.yaml --wait --timeout 6m

echo '== 6. Enterprise agentregistry'
echo "agentregistry licence from $AR_LICENSE_SOURCE (sha256 $(printf '%s' "$AGENTREGISTRY_LICENSE_KEY" | shasum -a 256 | cut -c1-8), ${#AGENTREGISTRY_LICENSE_KEY} chars)"
# Values from https://docs.solo.io/agentregistry/latest/setup/install/kubernetes.md (Keycloak option).
# arctl apply -f - with a stdin redirect works (run 9 Nov 2026, arctl v2026.8.0 against server 2026.10.0).
# The licence goes in through --set-file and a process substitution so it never appears in the process list.
# --set-file with <(...) works on Helm v4.2.0 (run 9 Nov 2026). The doc uses --set licensing.licenseKey=$AGENTREGISTRY_LICENSE_KEY.
helm --kube-context "$CTX" upgrade --install agentregistry "$AR_CHART" --version "$AR_VERSION" \
  --namespace agentregistry-system --create-namespace \
  --set licensing.createSecret=true \
  --set-file licensing.licenseKey=<(printf '%s' "$AGENTREGISTRY_LICENSE_KEY") \
  --set oidc.issuer="$KEYCLOAK_ISSUER" \
  --set oidc.clientId=ar-backend \
  --set-file oidc.clientSecret=<(printf '%s' "$AR_BACKEND_SECRET") \
  --set oidc.publicClientId=ar-ui \
  --set oidc.roleClaim=Groups \
  --set-string 'rbac.superAdminPrincipals[0].all[0].attribute=Groups' \
  --set-string 'rbac.superAdminPrincipals[0].all[0].values[0]=admins' \
  --wait --timeout 8m

echo '== 7. Gateway and parent route (platform team, once)'
kubectl --context "$CTX" apply -f yaml/gateway.yaml -f yaml/delegate-route.yaml
kubectl --context "$CTX" -n agentgateway-system wait --for=condition=Programmed gateway/agentgateway-proxy --timeout=180s
kubectl --context "$CTX" -n agentgateway-system wait --for=create deployment/agentgateway-proxy --timeout=180s
kubectl --context "$CTX" -n agentgateway-system rollout status deployment/agentgateway-proxy --timeout=360s

echo '== 8. Port-forwards for the laptop'
start_port_forwards

echo '== 9. Register and deploy through agentregistry'
export OIDC_ISSUER=$KEYCLOAK_ISSUER
arctl user login --oidc-flow=password-credentials --oidc-client-id=ar-cli-password \
  --oidc-username=admin-user --oidc-password=password
arctl apply -f - <registry/runtime.yaml
arctl apply -f - <registry/mcpservers.yaml
arctl apply -f - <registry/deployments.yaml
arctl apply -f - <registry/rbac.yaml
arctl apply -f - <registry/catalogue.yaml

echo '== 10. Sign-in policy and the PRM routes for the four servers'
kubectl --context "$CTX" apply -f yaml/oauth-metadata.yaml
kubectl --context "$CTX" apply --dry-run=server -f yaml/jwt-policy.yaml
kubectl --context "$CTX" apply -f yaml/jwt-policy.yaml

echo '== 11. One MCP path for all four servers (platform team, once)'
kubectl --context "$CTX" apply --dry-run=server -f yaml/one-path.yaml
kubectl --context "$CTX" apply -f yaml/one-path.yaml

kubectl --context "$CTX" -n agentregistry-system logs deploy/agentregistry-enterprise-server 2>/dev/null \
  | grep -iE 'license status|VALID LICENSE|LICENSE WARNING' | sed -E 's/"(ts|time)":"[^"]*",//' | tail -3 || true
# "agentregistry enterprise license missing or invalid" means the key is not an agentregistry licence. The registry
# still serves its API and the lab still runs. Checked 9 Nov 2026: none of the keys in the Solo secrets file at the
# time (agentgateway, gloo, gloo-mesh, gloo-mesh-gateway, gloo-core) was accepted as an agentregistry licence.
echo 'Up. Cluster, MCP servers and port-forwards stay running. Next: ./scripts/quick.sh test'
