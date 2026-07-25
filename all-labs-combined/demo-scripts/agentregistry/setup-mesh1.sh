#!/usr/bin/env bash
# setup-mesh1.sh — stand up the AgentRegistry demo platform ON mesh1, reusing the
# istio-ambient-demo-kind base (istio ambient + enterprise-agentgateway already
# installed by ../setup.sh). Adapted from agentregistry-agentcore-kind (source
# lab untouched): instead of localtest.me on host :80 + a NodePort ingress, we use
# mesh1's MetalLB LoadBalancer IP + *.<LB-IP>.sslip.io, so this never fights another
# kind cluster for host :80.
#
# Installs, in dedicated namespaces the reset removes:
#   ar-keycloak         — Keycloak (realm 'agentregistry'), the OIDC issuer
#   kagent              — Solo Enterprise for kagent (agent runtime)
#   agentregistry-system— in-cluster AgentRegistry (catalog/control plane)
#   + an ar-ingress agentgateway Gateway (LB IP) with HTTPRoutes to both
#
# Needs ANTHROPIC_API_KEY + SOLO_LICENSE_KEY (SECRETS_FILE) and gcloud auth.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log(){ echo "  $*" >&2; }
ok(){ echo "  ✓ $*" >&2; }
step(){ { echo; echo "══> $*"; } >&2; }
die(){ echo "ERROR: $*" >&2; exit 1; }

export CTX=kind-mesh1
export ISTIOCTL="${ISTIOCTL:-$HOME/.istioctl/bin/istioctl-1.30.3-solo}"
kc(){ kubectl --context "$CTX" "$@"; }

# ── secrets ───────────────────────────────────────────────────────────────────
SECRETS_FILE="${SECRETS_FILE:-$HOME/code/solo/secrets/secrets-envs.sh}"
[[ -f "$SECRETS_FILE" ]] && { set -a; source "$SECRETS_FILE"; set +a; }
export KAGENT_ENT_LICENSE_KEY="${KAGENT_ENT_LICENSE_KEY:-${SOLO_LICENSE_KEY:-${SOLO_ISTIO_LICENSE_KEY:-}}}"
[[ -n "${ANTHROPIC_API_KEY:-}" ]]      || die "ANTHROPIC_API_KEY not set (SECRETS_FILE)"
[[ -n "${KAGENT_ENT_LICENSE_KEY:-}" ]] || die "SOLO_LICENSE_KEY not set (SECRETS_FILE)"

# ── GAR auth for the Solo enterprise charts ────────────────────────────────────
GAR_HOST=us-docker.pkg.dev
gcloud auth print-access-token >/dev/null 2>&1 || die "gcloud not authenticated — run: gcloud auth login"
gcloud auth print-access-token | helm registry login -u oauth2accesstoken --password-stdin "$GAR_HOST" >/dev/null 2>&1 \
  && ok "helm authenticated to $GAR_HOST"

# ── chart / name constants (from the source lib.sh) ────────────────────────────
KEYCLOAK_NS=ar-keycloak
KEYCLOAK_REALM=agentregistry
KAGENT_NS=kagent
AR_NS=agentregistry-system
AR_VERSION=2026.6.1
AR_CHART="oci://us-docker.pkg.dev/solo-public/agentregistry-enterprise/helm/agentregistry-enterprise"
AR_SERVER_SVC=agentregistry-enterprise-server
AR_SERVER_PORT=12121
KAGENT_ENT_VERSION=0.4.3
KENT_CRDS_CHART="oci://us-docker.pkg.dev/solo-public/kagent-enterprise-helm/charts/kagent-enterprise-crds"
KENT_CHART="oci://us-docker.pkg.dev/solo-public/kagent-enterprise-helm/charts/kagent-enterprise"
AR_BACKEND_CLIENT=ar-backend
AR_UI_CLIENT=ar-ui
KAGENT_BACKEND_CLIENT=kagent-backend
RBAC_SUPERUSER_ROLE=admins

# ── ingress LB IP + sslip hosts ────────────────────────────────────────────────
step "agentgateway ingress (LB IP) + sslip.io hostnames"
kc apply -f - >/dev/null <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: { name: ar-ingress, namespace: agentgateway-system }
spec:
  gatewayClassName: enterprise-agentgateway
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes: { namespaces: { from: All } }
EOF
kc -n agentgateway-system wait --for=condition=Programmed gateway/ar-ingress --timeout=120s >/dev/null
LB=""; for _ in $(seq 1 40); do
  LB="$(kc -n agentgateway-system get gateway ar-ingress -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)"
  [[ -n "$LB" ]] && break; sleep 3
done
[[ -n "$LB" ]] || die "ar-ingress got no LB IP (MetalLB)"
export KEYCLOAK_HOST="keycloak.${LB}.sslip.io"
export AR_HOST="agentregistry.${LB}.sslip.io"
export KEYCLOAK_ISSUER="http://${KEYCLOAK_HOST}/realms/${KEYCLOAK_REALM}"
export ARCTL_API_BASE_URL="http://${AR_HOST}"
ok "LB ${LB}  ·  issuer ${KEYCLOAK_ISSUER}"

# ── Keycloak (agentregistry realm) in ar-keycloak ──────────────────────────────
step "Keycloak (realm ${KEYCLOAK_REALM}) in ${KEYCLOAK_NS}, KC_HOSTNAME=${KEYCLOAK_HOST}"
kc create namespace "$KEYCLOAK_NS" --dry-run=client -o yaml | kc apply -f - >/dev/null
kc -n "$KEYCLOAK_NS" create configmap keycloak-realm-import \
  --from-file=agentregistry-realm.json="$SCRIPT_DIR/yaml/keycloak/agentregistry-realm.json" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
# copied keycloak.yaml, rewritten for ar-keycloak ns + the sslip KC_HOSTNAME.
# BACKCHANNEL_DYNAMIC=false: the agentgateway ingress rewrites the Host header to the
# upstream service authority, so a dynamic backchannel would emit a token_endpoint of
# keycloak.<ns>.svc.cluster.local (unreachable from the host arctl runs on). Forcing it
# off pins every endpoint to KC_HOSTNAME (the sslip host); in-cluster clients reach that
# host via the bridge() hostAlias below.
sed -e "s/namespace: keycloak/namespace: ${KEYCLOAK_NS}/" \
    -e "s#http://keycloak.localtest.me#http://${KEYCLOAK_HOST}#" \
    -e 's/KC_HOSTNAME_BACKCHANNEL_DYNAMIC, value: "true"/KC_HOSTNAME_BACKCHANNEL_DYNAMIC, value: "false"/' \
    "$SCRIPT_DIR/yaml/keycloak/keycloak.yaml" | kc apply -f - >/dev/null
log "waiting for Keycloak (image pull + realm import can take 1-2 min)…"
kc -n "$KEYCLOAK_NS" rollout status statefulset/keycloak --timeout=300s >/dev/null || die "keycloak not Ready"
ok "Keycloak up"

step "Scraping confidential client secrets (ar-backend, kagent-backend)"
scrape() {
  local client="$1" pf admtok cid
  kc -n "$KEYCLOAK_NS" port-forward svc/keycloak 18099:8080 >/dev/null 2>&1 & pf=$!
  for _ in $(seq 1 30); do curl -sf -m2 http://localhost:18099/realms/master/.well-known/openid-configuration >/dev/null 2>&1 && break; sleep 1; done
  admtok="$(curl -s -X POST http://localhost:18099/realms/master/protocol/openid-connect/token \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d 'grant_type=password&client_id=admin-cli&username=admin&password=admin' | jq -r '.access_token // empty')"
  cid="$(curl -s -H "Authorization: Bearer $admtok" \
    "http://localhost:18099/admin/realms/${KEYCLOAK_REALM}/clients?clientId=${client}" | jq -r '.[0].id // empty')"
  curl -s -H "Authorization: Bearer $admtok" \
    "http://localhost:18099/admin/realms/${KEYCLOAK_REALM}/clients/${cid}/client-secret" | jq -r '.value // empty'
  kill "$pf" 2>/dev/null || true
}
AR_BACKEND_SECRET="$(scrape ar-backend)"
KAGENT_BACKEND_SECRET="$(scrape kagent-backend)"
[[ -n "$AR_BACKEND_SECRET" && -n "$KAGENT_BACKEND_SECRET" ]] || die "could not scrape client secrets"
ok "client secrets scraped"

# hostAlias helper: map the sslip issuer host -> Keycloak ClusterIP on a deployment
bridge() {
  local dep="$1" ns="$2" ip; ip="$(kc -n "$KEYCLOAK_NS" get svc keycloak -o jsonpath='{.spec.clusterIP}')"
  kc -n "$ns" patch deploy "$dep" --type=json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/hostAliases\",\"value\":[{\"ip\":\"$ip\",\"hostnames\":[\"$KEYCLOAK_HOST\"]}]}]" >/dev/null 2>&1 \
  || kc -n "$ns" patch deploy "$dep" --type=json \
    -p "[{\"op\":\"add\",\"path\":\"/spec/template/spec/hostAliases\",\"value\":[{\"ip\":\"$ip\",\"hostnames\":[\"$KEYCLOAK_HOST\"]}]}]" >/dev/null 2>&1 || true
}

# ── kagent-enterprise ──────────────────────────────────────────────────────────
step "Installing kagent-enterprise ${KAGENT_ENT_VERSION}"
kc create namespace "$KAGENT_NS" --dry-run=client -o yaml | kc apply -f - >/dev/null
kc -n "$KAGENT_NS" get secret jwt >/dev/null 2>&1 || {
  t="$(mktemp)"; openssl genpkey -algorithm RSA -out "$t" -pkeyopt rsa_keygen_bits:2048 >/dev/null 2>&1
  kc -n "$KAGENT_NS" create secret generic jwt --from-file=jwt="$t" >/dev/null; rm -f "$t"; }
kc -n "$KAGENT_NS" create secret generic kagent-enterprise-oidc-secret \
  --from-literal=clientSecret="$KAGENT_BACKEND_SECRET" --dry-run=client -o yaml | kc apply -f - >/dev/null
helm --kube-context "$CTX" upgrade --install kagent-crds "$KENT_CRDS_CHART" \
  -n "$KAGENT_NS" --create-namespace --version "$KAGENT_ENT_VERSION" --wait --timeout 5m >/dev/null
ok "kagent CRDs installed"
kc -n "$KAGENT_NS" delete configmap kagent-ui-config --ignore-not-found >/dev/null 2>&1 || true
helm --kube-context "$CTX" upgrade --install kagent "$KENT_CHART" -n "$KAGENT_NS" --version "$KAGENT_ENT_VERSION" \
  --set global.licensing.licenseKey="$KAGENT_ENT_LICENSE_KEY" \
  --set providers.default=anthropic \
  --set providers.anthropic.apiKey="$ANTHROPIC_API_KEY" \
  --set oidc.issuer="$KEYCLOAK_ISSUER" \
  --set oidc.clientId="$KAGENT_BACKEND_CLIENT" \
  --set oidc.secretRef=kagent-enterprise-oidc-secret --set oidc.secretKey=clientSecret --set oidc.skipOBO=false \
  --set-json 'controller.envFrom=[{"configMapRef":{"name":"kagent-enterprise-config"}}]' \
  --set kagent-tools.enabled=true --set ui.enabled=false \
  --set otel.tracing.enabled=false --set otel.logging.enabled=false \
  --set-json 'rbac.roleMapping={"roleMapper":"claims.Groups.transformList(i, v, v in rolesMap, rolesMap[v])","roleMappings":{"admins":"global.Admin","readers":"global.Reader","writers":"global.Writer"}}' \
  --timeout 12m >/dev/null &
KAGENT_PID=$!

# ── in-cluster AgentRegistry ───────────────────────────────────────────────────
step "Installing AgentRegistry ${AR_VERSION} in ${AR_NS}"
helm --kube-context "$CTX" upgrade --install agentregistry "$AR_CHART" -n "$AR_NS" --create-namespace --version "$AR_VERSION" \
  --set oidc.issuer="$KEYCLOAK_ISSUER" \
  --set oidc.clientId="$AR_BACKEND_CLIENT" --set oidc.clientSecret="$AR_BACKEND_SECRET" \
  --set oidc.publicClientId="$AR_UI_CLIENT" \
  --set oidc.roleClaim=Groups --set oidc.superuserRole="$RBAC_SUPERUSER_ROLE" \
  --set kagent.outboundAuth.oidc.clientId="$KAGENT_BACKEND_CLIENT" \
  --set kagent.outboundAuth.oidc.clientSecret="$KAGENT_BACKEND_SECRET" \
  --set database.postgres.type=bundled >/dev/null
ok "AgentRegistry chart applied"

step "Waiting for kagent controller + wiring issuer hostAlias"
wait "$KAGENT_PID" 2>/dev/null || true
ok "kagent chart applied"
bridge kagent-controller "$KAGENT_NS" && ok "hostAlias on kagent-controller"
for _ in $(seq 1 30); do kc -n "$AR_NS" get deploy "$AR_SERVER_SVC" >/dev/null 2>&1 && break; sleep 3; done
bridge "$AR_SERVER_SVC" "$AR_NS" && ok "hostAlias on ${AR_SERVER_SVC}"
kc -n "$KAGENT_NS" rollout status deploy/kagent-controller --timeout=360s >/dev/null 2>&1 && ok "kagent controller Ready" || log "kagent controller not Ready yet"
kc -n "$AR_NS" rollout status deploy/"$AR_SERVER_SVC" --timeout=360s >/dev/null 2>&1 && ok "AgentRegistry server Ready" || log "AR server not Ready yet"

# Enroll the kagent namespace in the ambient mesh so a kagent AccessPolicy can
# enforce MCP tool access at an agentgateway waypoint (demo-4 governance step). The
# agent's traffic to an MCP Service is captured by ztunnel and routed through the
# waypoint ONLY when the client namespace is ambient; the network label must match
# ztunnel's NETWORK (mesh1) or the HBONE hop is cross-network and never lands.
kc label ns "$KAGENT_NS" istio.io/dataplane-mode=ambient --overwrite >/dev/null
kc label ns "$KAGENT_NS" topology.istio.io/network=mesh1 --overwrite >/dev/null
ok "kagent namespace enrolled in ambient (network=mesh1)"

# ── Kyverno model-key injection (agents deploy keyless) ────────────────────────
step "Kyverno model-key injection policy"
KYVERNO_VER="${KYVERNO_VERSION:-v1.13.4}"
kc get deploy -n kyverno kyverno-admission-controller >/dev/null 2>&1 || {
  kc apply --server-side --force-conflicts -f "https://github.com/kyverno/kyverno/releases/download/${KYVERNO_VER}/install.yaml" >/dev/null 2>&1
  kc -n kyverno rollout status deploy/kyverno-admission-controller --timeout=180s >/dev/null 2>&1 || log "kyverno not Ready"; }
kc -n "$KAGENT_NS" create secret generic kagent-anthropic --from-literal=ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
kc apply -f "$SCRIPT_DIR/yaml/kyverno/inject-agent-model-key.yaml" >/dev/null 2>&1 && ok "Kyverno policy applied" || log "kyverno policy apply skipped"

# ── ingress HTTPRoutes (keycloak + agentregistry at sslip hosts) ───────────────
step "Ingress HTTPRoutes"
kc apply -f - >/dev/null <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: keycloak, namespace: ${KEYCLOAK_NS} }
spec:
  parentRefs: [{ name: ar-ingress, namespace: agentgateway-system }]
  hostnames: ["${KEYCLOAK_HOST}"]
  rules: [{ matches: [{ path: { type: PathPrefix, value: / } }], backendRefs: [{ name: keycloak, port: 80 }] }]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: agentregistry, namespace: ${AR_NS} }
spec:
  parentRefs: [{ name: ar-ingress, namespace: agentgateway-system }]
  hostnames: ["${AR_HOST}"]
  rules: [{ matches: [{ path: { type: PathPrefix, value: / } }], backendRefs: [{ name: ${AR_SERVER_SVC}, port: ${AR_SERVER_PORT} }] }]
EOF
ok "routes applied: ${KEYCLOAK_HOST}, ${AR_HOST}"

# ── register the kagent runtime + seed the approved catalog (engineer pre-work) ──
# The notebook's "browse" step and `arctl init agent --mcp <ref>` both expect the
# catalog to already hold the approved MCP servers + skill, and deploys target the
# kind-kagent runtime. Do that one-time work here so the demo is a clean read.
step "Registering kind-kagent runtime + seeding the catalog"
export PATH="$HOME/.arctl/bin:$PATH" NO_COLOR=1 CLICOLOR=0 TERM=dumb
export REG_NAME="${REG_NAME:-kind-registry}" REG_PORT="${REG_PORT:-5001}"
for _ in $(seq 1 60); do curl -sf -m2 -o /dev/null "${KEYCLOAK_ISSUER}/.well-known/openid-configuration" && break; sleep 2; done
unset ARCTL_API_TOKEN
for _ in 1 2 3 4 5; do
  OIDC_ISSUER="$KEYCLOAK_ISSUER" OIDC_CLIENT_ID=ar-cli-password \
  arctl user login --oidc-flow password-credentials --oidc-issuer-url "$KEYCLOAK_ISSUER" \
    --oidc-client-id ar-cli-password --oidc-username admin-user --oidc-password password >/dev/null 2>&1 && break
  sleep 3
done
# kind-kagent runtime (type Kagent: deploys via the controller HTTP API, forwarding
# the caller's bearer; reached by plain Service DNS now the registry runs in-cluster).
arctl apply -f - >/dev/null 2>&1 <<RT
apiVersion: ar.dev/v1alpha1
kind: Runtime
metadata: { name: kind-kagent }
spec:
  type: Kagent
  telemetryEndpoint: http://agentregistry-enterprise-telemetry-collector.${AR_NS}.svc.cluster.local:4318
  config: { kagentUrl: "http://kagent-controller.kagent:8083", namespace: kagent }
RT
for r in virtual-default kubernetes-default; do arctl delete runtime "$r" >/dev/null 2>&1 || true; done
ok "runtime kind-kagent registered"
# approved MCP tool servers + skill: build each image -> localhost:5001, publish the CR
for s in everything-server my-mcp; do
  arctl build "$SCRIPT_DIR/mcp/$s" --push >/dev/null 2>&1 \
    && arctl apply -f "$SCRIPT_DIR/mcp/$s/mcp.yaml" >/dev/null 2>&1 \
    && ok "published $s" || log "publish $s failed — re-run scripts/connect.sh then arctl build/apply"
done
arctl apply -f "$SCRIPT_DIR/skill/dice-game/skill.yaml" >/dev/null 2>&1 && ok "published dice-game skill" || true

# ── record the runtime env for the notebook / arctl ────────────────────────────
cat > "$SCRIPT_DIR/.env.mesh1" <<EOF
export CTX=kind-mesh1
export LB=${LB}
export KEYCLOAK_HOST=${KEYCLOAK_HOST}
export AR_HOST=${AR_HOST}
export KEYCLOAK_ISSUER=${KEYCLOAK_ISSUER}
export ARCTL_API_BASE_URL=${ARCTL_API_BASE_URL}
export KEYCLOAK_NS=${KEYCLOAK_NS}
EOF
ok "wrote $SCRIPT_DIR/.env.mesh1"

echo "" >&2
echo "════════════════════════════════════════════════════════════════════" >&2
echo "  AgentRegistry demo platform on mesh1 — up" >&2
echo "    registry API/UI : http://${AR_HOST}" >&2
echo "    Keycloak issuer : ${KEYCLOAK_ISSUER}" >&2
echo "    arctl login     : arctl user login --api-server-url http://${AR_HOST} ..." >&2
echo "════════════════════════════════════════════════════════════════════" >&2
