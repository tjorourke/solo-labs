#!/usr/bin/env bash
# init-demo.sh — bootstrap rvennam's agentgateway-enterprise-demo notebook
# against the cluster that quick.sh just stood up.
#
# What this does (idempotent):
#   1. Creates the `agentgateway-proxy` Gateway in agentgateway-system on
#      CLUSTER1 (the notebook references this name in every section).
#   2. Cross-namespace ReferenceGrant so HTTPRoutes from ai-models /
#      mcp-servers (created by the notebook's init.sh) can attach to it.
#   3. Port-forwards Keycloak to localhost:18080 (in the background).
#   4. Emits ~/.auth0.env populated with the Keycloak `agentgw-demo` client
#      credentials so the notebook's setup cell needs zero changes other
#      than ONE URL tweak in §8 cell 53 (token URL — see PATCH below).
#
# Usage:
#   ./init-demo.sh           # set up
#   ./init-demo.sh down      # tear down (deletes Gateway, kills port-forward,
#                            #  removes ~/.auth0.env)

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CLUSTER1="${CLUSTER1:-kind-east-ag}"
NS="${NS:-agentgateway-system}"
KEYCLOAK_NS="${KEYCLOAK_NS:-keycloak}"
KEYCLOAK_REALM="solo"
KEYCLOAK_CLIENT_ID="agentgw-demo"
# Matches the `secret` field in yaml/keycloak/realm-solo.json.
KEYCLOAK_CLIENT_SECRET="dev-secret-do-not-use-in-prod"
# Port-forward port that the notebook's curl will hit.
KEYCLOAK_LOCAL_PORT="${KEYCLOAK_LOCAL_PORT:-18080}"

AUTH0_ENV_FILE="${AUTH0_ENV_FILE:-$HOME/.auth0.env}"
PF_PID_FILE="${PF_PID_FILE:-/tmp/agentgw-demo-keycloak-pf.pid}"

log()    { echo "  $*"; }
log_ok() { echo "  ✓ $*"; }
step()   { echo ""; echo "══> $*"; }

if [[ "${1:-}" == "down" ]]; then
  step "Tearing down agentgateway-enterprise-demo bootstrap"
  kubectl --context "$CLUSTER1" -n "$NS" delete \
    gateway/agentgateway-proxy referencegrant/from-ai-models referencegrant/from-mcp-servers \
    --ignore-not-found >/dev/null || true
  if [[ -f "$PF_PID_FILE" ]] && kill -0 "$(cat "$PF_PID_FILE")" 2>/dev/null; then
    kill "$(cat "$PF_PID_FILE")" 2>/dev/null || true
    rm -f "$PF_PID_FILE"
    log_ok "killed keycloak port-forward"
  fi
  rm -f "$AUTH0_ENV_FILE" && log_ok "removed $AUTH0_ENV_FILE"
  exit 0
fi

step "Enabling AGW tokenExchange STS (Keycloak JWKS-backed)"
# Build the inline tokenExchange config JSON. issuer is what the STS stamps
# on the tokens it issues; subjectValidator/apiValidator point at the
# Keycloak JWKS so the STS will accept Keycloak-issued JWTs and exchange
# them for AGW-issued tokens. actorValidator stays on `k8s` so the proxy's
# SA token authenticates the proxy itself to the STS.
KEYCLOAK_JWKS="http://keycloak.$KEYCLOAK_NS.svc.cluster.local/realms/$KEYCLOAK_REALM/protocol/openid-connect/certs"
TOKEN_EXCHANGE_CFG=$(cat <<EOF
{
  "enabled": true,
  "issuer": "enterprise-agentgateway.$NS.svc.cluster.local:7777",
  "subjectValidator": { "validatorType": "remote", "remoteConfig": { "url": "$KEYCLOAK_JWKS" } },
  "actorValidator":   { "validatorType": "k8s" },
  "apiValidator":     { "validatorType": "remote", "remoteConfig": { "url": "$KEYCLOAK_JWKS" } },
  "tokenExpiration": "24h"
}
EOF
)
# Wait for Keycloak Service to resolve (DNS race after fresh install).
for i in $(seq 1 30); do
  kubectl --context "$CLUSTER1" -n "$KEYCLOAK_NS" get svc keycloak >/dev/null 2>&1 && break
  sleep 2
done
# Sanity-check JWKS reachability from inside the cluster.
if kubectl --context "$CLUSTER1" run jwks-probe --rm -i --restart=Never \
     --image=curlimages/curl:8.10.1 --timeout=30s --command -- \
     curl -sf "$KEYCLOAK_JWKS" -o /dev/null >/dev/null 2>&1; then
  log_ok "Keycloak JWKS reachable: $KEYCLOAK_JWKS"
else
  log "warning: JWKS probe failed; AGW pod may crash-loop until Keycloak is fully up"
fi
helm --kube-context "$CLUSTER1" upgrade --install enterprise-agentgateway \
  "${AGW_CHART:-oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway}" \
  --reuse-values \
  --namespace "$NS" \
  --version "${AGW_VERSION:-v2026.5.1}" \
  --set-json "tokenExchange=$TOKEN_EXCHANGE_CFG" \
  --wait --timeout 5m >/dev/null
log_ok "AGW upgraded with tokenExchange enabled (issuer + Keycloak JWKS wired)"

step "Creating agentgateway-proxy Gateway on ${CLUSTER1#kind-}"
kubectl --context "$CLUSTER1" apply -f - <<EOF >/dev/null
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: agentgateway-proxy
  namespace: $NS
spec:
  gatewayClassName: enterprise-agentgateway
  listeners:
  - name: http
    protocol: HTTP
    port: 8080
    allowedRoutes:
      namespaces:
        from: All
---
# The notebook's init.sh creates HTTPRoutes in ai-models / mcp-servers that
# attach to this Gateway in agentgateway-system. Permit it.
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: from-ai-models
  namespace: $NS
spec:
  from:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    namespace: ai-models
  to:
  - group: ""
    kind: Service
---
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: from-mcp-servers
  namespace: $NS
spec:
  from:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    namespace: mcp-servers
  to:
  - group: ""
    kind: Service
EOF
log_ok "Gateway agentgateway-proxy applied"

# Wait for the controller to provision the proxy Deployment + Service.
for i in $(seq 1 60); do
  if kubectl --context "$CLUSTER1" -n "$NS" get deploy agentgateway-proxy >/dev/null 2>&1; then
    log_ok "Deployment agentgateway-proxy provisioned"
    break
  fi
  sleep 2
done

step "Starting Keycloak port-forward on localhost:$KEYCLOAK_LOCAL_PORT"
if [[ -f "$PF_PID_FILE" ]] && kill -0 "$(cat "$PF_PID_FILE")" 2>/dev/null; then
  log_ok "port-forward already running (PID $(cat "$PF_PID_FILE"))"
else
  kubectl --context "$CLUSTER1" -n "$KEYCLOAK_NS" \
    port-forward svc/keycloak "${KEYCLOAK_LOCAL_PORT}:80" \
    >/tmp/agentgw-demo-keycloak-pf.log 2>&1 &
  echo $! > "$PF_PID_FILE"
  sleep 2
  if kill -0 "$(cat "$PF_PID_FILE")" 2>/dev/null; then
    log_ok "port-forward running (PID $(cat "$PF_PID_FILE"), log /tmp/agentgw-demo-keycloak-pf.log)"
  else
    log "port-forward failed — check /tmp/agentgw-demo-keycloak-pf.log"
  fi
fi

step "Writing $AUTH0_ENV_FILE for the demo notebook"
# The notebook sources this file as-is. We populate Auth0-named env vars
# with Keycloak coords — the AUTH0_DOMAIN value is the Keycloak host:port
# (no scheme), so the notebook's `https://$AUTH0_DOMAIN/...` URL still
# works, modulo the one path change documented in PATCH below.
cat > "$AUTH0_ENV_FILE" <<EOF
# Auto-generated by init-demo.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ).
# Keycloak (in place of Auth0) for the agentgateway-enterprise-demo notebook.
# Keycloak realm: $KEYCLOAK_REALM, client: $KEYCLOAK_CLIENT_ID.
export AUTH0_DOMAIN="localhost:$KEYCLOAK_LOCAL_PORT"
export AUTH0_AUDIENCE="https://agentgw-demo/"
export AUTH0_CLIENT_ID="$KEYCLOAK_CLIENT_ID"
export AUTH0_CLIENT_SECRET="$KEYCLOAK_CLIENT_SECRET"
# Keycloak-specific: realm + token URL path (Auth0 uses /oauth/token,
# Keycloak uses /realms/<realm>/protocol/openid-connect/token).
export KEYCLOAK_REALM="$KEYCLOAK_REALM"
export AUTH0_TOKEN_PATH="/realms/$KEYCLOAK_REALM/protocol/openid-connect/token"
export AUTH0_JWKS_URL="http://keycloak.$KEYCLOAK_NS.svc.cluster.local/realms/$KEYCLOAK_REALM/protocol/openid-connect/certs"
EOF
chmod 600 "$AUTH0_ENV_FILE"
log_ok "$AUTH0_ENV_FILE written (mode 600)"

cat <<EOF

──────────────────────────────────────────────────────────────────────────────
PATCH for demo.ipynb §8 cell 53 (one line change so Keycloak's token URL is
called instead of Auth0's):

  -    AUTH0_TOKEN=\$(curl -sS -X POST "https://\$AUTH0_DOMAIN/oauth/token" \\
  +    AUTH0_TOKEN=\$(curl -sS -X POST "http://\$AUTH0_DOMAIN\${AUTH0_TOKEN_PATH:-/oauth/token}" \\

(http, not https — kind→localhost port-forward is plain HTTP. AUTH0_TOKEN_PATH
falls back to /oauth/token so the same notebook still works against real
Auth0 if you swap ~/.auth0.env back.)

You can now open demo.ipynb and run the cells top-to-bottom.
──────────────────────────────────────────────────────────────────────────────
EOF
