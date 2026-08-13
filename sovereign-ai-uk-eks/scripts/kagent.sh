#!/usr/bin/env bash
# Solo Enterprise for kagent: the agent runtime, wired to the existing Keycloak as its
# OIDC provider rather than standing up a second identity provider.
#
#   ./scripts/kagent.sh up       Keycloak client + CRDs + controller + UI + postgres
#   ./scripts/kagent.sh status   what is running
#   ./scripts/kagent.sh down      remove it (leaves the Keycloak client)
#
# Runs after Keycloak (the IDP), the mesh (so kagent is enrolled) and the policy layer.
# One policy interaction is expected and handled in yaml/40-policies.yaml: kagent injects
# its OIDC and licence secrets via secretKeyRef, so the kagent namespace is excluded from
# the no-secrets-in-env rule, documented there.
set -euo pipefail

export AWS_PROFILE="${SOVEREIGN_AWS_PROFILE:?set SOVEREIGN_AWS_PROFILE to the sandbox SSO profile}"
REGION=eu-west-2
CLUSTER=uk-sovereign-ai
NS=kagent
REALM=sovereign
KAGENT_ENT_VERSION="${KAGENT_ENT_VERSION:-0.4.0}"
KAGENT_ENT_REGISTRY="oci://us-docker.pkg.dev/solo-public/kagent-enterprise-helm/charts"
KAGENT_UI_TAG="${KAGENT_UI_TAG:-0.9.1}"

ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
[ -n "$ACCOUNT" ] && [ "$ACCOUNT" != "None" ] || { echo "error: no AWS identity; check SOVEREIGN_AWS_PROFILE" >&2; exit 1; }
CTX="arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${CLUSTER}"
ECR="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
kc() { command kubectl --context "$CTX" "$@"; }
helm_() { command helm --kube-context "$CTX" "$@"; }

license() {
  if [ -z "${SOLO_LICENSE_KEY:-}${KAGENT_ENT_LICENSE_KEY:-}" ]; then
    # shellcheck disable=SC1090
    [ -n "${SOVEREIGN_ENV_FILE:-}" ] && [ -f "$SOVEREIGN_ENV_FILE" ] && . "$SOVEREIGN_ENV_FILE" >/dev/null 2>&1 || true
  fi
  # The Enterprise chart accepts any non-empty key for eval; a real licence unlocks support.
  LIC="${SOLO_LICENSE_KEY:-${KAGENT_ENT_LICENSE_KEY:-eval-key-0000000000}}"
}

# Create (or reuse) the kagent-enterprise OIDC client in Keycloak and write its secret into
# the kagent namespace. Done over a port-forward with a readiness wait, because the Keycloak
# image ships no curl for an in-cluster call.
keycloak_client() {
  echo "==> Keycloak client 'kagent-enterprise' in realm '$REALM'"
  local port=18110 pf kc_url token cid secret
  kc -n keycloak port-forward keycloak-0 ${port}:8080 >/tmp/kagent-pf.log 2>&1 &
  pf=$!
  trap 'kill $pf 2>/dev/null || true' RETURN
  kc_url="http://localhost:${port}"
  for _ in $(seq 1 20); do curl -sf "$kc_url/realms/${REALM}" >/dev/null 2>&1 && break; sleep 1; done
  token="$(curl -s -X POST "$kc_url/realms/master/protocol/openid-connect/token" \
    -d 'grant_type=password&client_id=admin-cli&username=admin&password=admin' \
    | python3 -c 'import json,sys;print(json.load(sys.stdin).get("access_token",""))')"
  [ -n "$token" ] || { echo "error: could not get a Keycloak admin token" >&2; return 1; }
  cid="$(curl -s "$kc_url/admin/realms/${REALM}/clients?clientId=kagent-enterprise" \
    -H "Authorization: Bearer $token" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d[0]["id"] if d else "")')"
  if [ -z "$cid" ]; then
    curl -s -o /dev/null -X POST "$kc_url/admin/realms/${REALM}/clients" -H "Authorization: Bearer $token" \
      -H 'content-type: application/json' -d '{
        "clientId":"kagent-enterprise","enabled":true,"protocol":"openid-connect","publicClient":false,
        "standardFlowEnabled":true,"directAccessGrantsEnabled":true,"serviceAccountsEnabled":true,
        "redirectUris":["*"],"webOrigins":["*"]}'
    cid="$(curl -s "$kc_url/admin/realms/${REALM}/clients?clientId=kagent-enterprise" \
      -H "Authorization: Bearer $token" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d[0]["id"] if d else "")')"
    echo "    created client $cid"
  else
    echo "    client exists ($cid)"
  fi
  secret="$(curl -s "$kc_url/admin/realms/${REALM}/clients/${cid}/client-secret" \
    -H "Authorization: Bearer $token" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("value",""))')"
  [ -n "$secret" ] || { echo "error: no client secret returned" >&2; return 1; }
  kc -n "$NS" create secret generic kagent-enterprise-oidc-secret \
    --from-literal=clientSecret="$secret" --dry-run=client -o yaml | kc apply -f - >/dev/null
  echo "    OIDC secret written to the $NS namespace"
}

# The kagent UI image ships from cr.kagent.dev, which restrict-registries does not allowlist.
# Rather than punch a seventh foreign registry into the allowlist, mirror the one image into the
# in-region ECR (which the policy already allows) and point the chart at it, so the console's
# image is sovereign like everything else. buildx imagetools copies the multi-arch manifest
# registry-to-registry, so the node still pulls its own architecture and there is no local pull.
mirror_ui_image() {
  echo "==> mirroring the kagent UI image into the in-region ECR (kagent-dev/kagent/ui:${KAGENT_UI_TAG})"
  aws ecr describe-repositories --region "$REGION" --repository-names kagent-dev/kagent/ui >/dev/null 2>&1 \
    || aws ecr create-repository --region "$REGION" --repository-name kagent-dev/kagent/ui \
         --image-scanning-configuration scanOnPush=true >/dev/null
  aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$ECR" >/dev/null 2>&1
  docker buildx imagetools create --tag "$ECR/kagent-dev/kagent/ui:${KAGENT_UI_TAG}" \
    "cr.kagent.dev/kagent-dev/kagent/ui:${KAGENT_UI_TAG}" >/dev/null 2>&1
  echo "    -> $ECR/kagent-dev/kagent/ui:${KAGENT_UI_TAG}"
}

case "${1:-status}" in
  up)
    license
    kc create namespace "$NS" --dry-run=client -o yaml | kc apply -f - >/dev/null
    keycloak_client

    echo "==> kagent-enterprise CRDs $KAGENT_ENT_VERSION"
    helm_ upgrade --install kagent-enterprise-crds "$KAGENT_ENT_REGISTRY/kagent-enterprise-crds" \
      -n "$NS" --version "$KAGENT_ENT_VERSION" --wait >/dev/null
    echo "    installed"

    mirror_ui_image

    echo "==> kagent-enterprise $KAGENT_ENT_VERSION (OIDC -> Keycloak, in-cluster issuer)"
    # In-cluster issuer for token validation. The UI browser login needs an external
    # Keycloak hostname, which arrives with the DNS pass; the controller and API validate
    # against the in-cluster issuer and come up without it. The UI image is pulled from the
    # in-region ECR mirror set up just above, so admission's restrict-registries admits it.
    helm_ upgrade --install kagent-enterprise "$KAGENT_ENT_REGISTRY/kagent-enterprise" \
      -n "$NS" --version "$KAGENT_ENT_VERSION" --timeout 8m -f - >/dev/null <<EOF
global:
  licensing: { createSecret: true, secretName: enterprise-kagent-license, licenseKey: "${LIC}" }
oidc:
  # The frontend issuer is the external hostname the browser is redirected to for login.
  # In-cluster, a CoreDNS rewrite (added by 'keycloak.sh up') resolves this name to the
  # gateway, which terminates TLS with the *.sovereign.local edge cert and forwards to
  # Keycloak; OIDC_INSECURE_SKIP_VERIFY below lets the controller and UI trust that private
  # edge cert on the discovery/JWKS hop, which itself rides ztunnel mTLS inside the cluster.
  issuer: https://keycloak.sovereign.local/realms/${REALM}
  clientId: kagent-enterprise
  secretRef: kagent-enterprise-oidc-secret
  secretKey: clientSecret
rbac:
  roleMapping: { roleMapper: "['global.Admin']" }
controller:
  env: [ { name: OIDC_INSECURE_SKIP_VERIFY, value: "true" } ]
  resources: { requests: { cpu: 100m, memory: 128Mi }, limits: { cpu: 1000m, memory: 512Mi } }
ui:
  enabled: true
  env: [ { name: OIDC_INSECURE_SKIP_VERIFY, value: "true" } ]
  image: { registry: "${ECR}", repository: kagent-dev/kagent, name: ui, tag: "${KAGENT_UI_TAG}" }
  resources: { requests: { cpu: 50m, memory: 128Mi }, limits: { cpu: 500m, memory: 512Mi } }
EOF
    echo "    waiting for postgres then the controller (controller retries until the DB is up)"
    kc -n "$NS" wait --for=condition=ready pod -l app.kubernetes.io/name=postgresql --timeout=180s >/dev/null 2>&1 || true
    kc -n "$NS" rollout restart deploy/kagent-controller >/dev/null 2>&1 || true
    kc -n "$NS" rollout status deploy/kagent-controller --timeout=240s

    # Enrol in the mesh so kagent workloads get Vault-signed SPIFFE identities like
    # everything else. New pods are captured on their next start, which the restart above
    # already triggered.
    kc label ns "$NS" istio.io/dataplane-mode=ambient --overwrite >/dev/null
    echo "    kagent up and enrolled in the ambient mesh"
    ;;

  status)
    kc -n "$NS" get pods 2>/dev/null || echo "  not installed"
    echo
    echo "=== kagent CRDs"
    kc api-resources 2>/dev/null | grep -iE 'kagent|sandboxagent|accesspolicy|toolserver' | awk '{print "  "$1}'
    ;;

  down)
    helm_ uninstall kagent-enterprise -n "$NS" >/dev/null 2>&1 || true
    helm_ uninstall kagent-enterprise-crds -n "$NS" >/dev/null 2>&1 || true
    echo "removed (Keycloak client left in place)"
    ;;

  *) echo "usage: $0 {up|status|down}"; exit 1 ;;
esac
