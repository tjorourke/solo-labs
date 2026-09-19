#!/usr/bin/env bash
# agentdesktop.sh — stand up the Part 9 (Agentdesktop fleet) platform on mesh1,
# on top of ./demo-scripts/setup.sh and ./demo-scripts/llm-gateway.sh.
#
#   - keycloak: a "corp" realm with a public agentdesktop client and three
#     staff users, exposed on a MetalLB address so the laptop browser and the
#     in-cluster controller resolve the same issuer string
#   - agentdesktop ns: PostgreSQL, the controller TLS material (device CA,
#     controller certificate, gateway JWT signing key) and the controller
#     itself from the published image
#   - ai-gateway: a JWT policy that accepts only controller-minted tokens, and
#     an Anthropic route that answers the native /v1/messages API Claude Code
#     speaks
#
#   ./demo-scripts/agentdesktop.sh
#
# No secrets are needed here. The Anthropic key was already stored in the
# cluster by llm-gateway.sh; this script never sees it.
#
# Idempotent — re-run freely. Remove with: ./demo-scripts/agentdesktop.sh teardown
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CTX="${CTX:-kind-mesh1}"
GW_NS=agentgateway-system
AD_NS=agentdesktop
KC_NS=keycloak
REALM=corp
CLIENT_ID=agentdesktop
# The controller image publishes only :latest. The chart would otherwise
# default image.tag to its appVersion (0.1.0), which is not a published tag.
CONTROLLER_IMAGE_TAG="${CONTROLLER_IMAGE_TAG:-latest}"
# The controller chart ships in the project repository. Point AGENTDESKTOP_CHART
# at a checkout you already have, otherwise a shallow clone is made next to this
# script and reused.
AGENTDESKTOP_REPO="${AGENTDESKTOP_REPO:-https://github.com/agentdesktop-dev/agentdesktop.git}"
CHART="${AGENTDESKTOP_CHART:-}"

step() { printf '\n\033[1;36m══> %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
log()  { printf '  %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }
kc()   { kubectl --context "$CTX" "$@"; }

if [ "${1:-}" = "teardown" ]; then
  step "Removing the Agentdesktop fleet platform"
  helm --kube-context "$CTX" uninstall agentdesktop -n "$AD_NS" 2>/dev/null || true
  kc delete ns "$AD_NS" --ignore-not-found
  kc -n "$KC_NS" delete svc keycloak-lb --ignore-not-found
  kc -n "$GW_NS" delete enterpriseagentgatewaypolicy agentdesktop-jwt --ignore-not-found
  kc -n "$GW_NS" delete httproute agentdesktop-messages --ignore-not-found
  kc -n "$AD_NS" delete agentgatewaypolicy agentdesktop-controller-tls --ignore-not-found 2>/dev/null || true
  echo ""; echo "Done. The corp realm is removed with the namespace; Keycloak itself stays."
  exit 0
fi

# ── Prereqs ───────────────────────────────────────────────────────────────────
step "Checking prereqs"
for t in kubectl helm openssl jq curl git; do command -v "$t" >/dev/null || die "$t not found"; done
kc get ns "$GW_NS" >/dev/null 2>&1 || die "$GW_NS missing — run ./demo-scripts/setup.sh first"
kc -n "$GW_NS" get gateway ai-gateway >/dev/null 2>&1 \
  || die "ai-gateway missing — run ./demo-scripts/llm-gateway.sh first"
kc -n "$GW_NS" get secret anthropic-secret >/dev/null 2>&1 \
  || die "anthropic-secret missing — run ./demo-scripts/llm-gateway.sh first"
if [ -z "$CHART" ]; then
  SRC_DIR="$SCRIPT_DIR/.agentdesktop-src"
  if [ ! -d "$SRC_DIR/.git" ]; then
    log "fetching the Agentdesktop chart from $AGENTDESKTOP_REPO"
    git clone --depth 1 "$AGENTDESKTOP_REPO" "$SRC_DIR" >/dev/null 2>&1 \
      || die "could not clone $AGENTDESKTOP_REPO (set AGENTDESKTOP_CHART to a local checkout instead)"
  fi
  CHART="$SRC_DIR/deploy/helm/agentdesktop-controller"
fi
[ -d "$CHART" ] || die "controller chart not found at $CHART (set AGENTDESKTOP_CHART)"
ok "tools, ai-gateway and the Anthropic secret are present"

# ── 1. Keycloak on a routable address ─────────────────────────────────────────
# The issuer string has to be identical for the in-cluster controller and the
# laptop browser, so both use the service DNS name. The laptop resolves it via
# /etc/hosts to the MetalLB address printed at the end.
step "Exposing Keycloak on a MetalLB address"
kc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Service
metadata:
  name: keycloak-lb
  namespace: $KC_NS
  labels: { app: keycloak }
spec:
  type: LoadBalancer
  selector: { app: keycloak }
  ports:
    - { name: http, port: 8080, targetPort: 8080 }
EOF
for _ in $(seq 1 60); do
  KC_IP="$(kc -n "$KC_NS" get svc keycloak-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [ -n "${KC_IP:-}" ] && break; sleep 2
done
[ -n "${KC_IP:-}" ] || die "Keycloak LoadBalancer never received an address"
ok "keycloak-lb = $KC_IP"

ISSUER="http://keycloak.$KC_NS.svc.cluster.local:8080/realms/$REALM"

# ── 2. The corp realm, client and staff ───────────────────────────────────────
# kcadm.sh runs inside the pod, so this needs no port-forward and no ingress.
step "Keycloak realm '$REALM' + public client '$CLIENT_ID'"
KC_POD="$(kc -n "$KC_NS" get pod -l app=keycloak -o jsonpath='{.items[0].metadata.name}')"
kcadm() { kc -n "$KC_NS" exec "$KC_POD" -- /opt/keycloak/bin/kcadm.sh "$@"; }

kcadm config credentials --server http://localhost:8080 \
  --realm master --user admin --password admin >/dev/null 2>&1 \
  || die "could not authenticate to Keycloak as admin"

if kcadm get "realms/$REALM" >/dev/null 2>&1; then
  ok "realm $REALM already present"
else
  kcadm create realms -s realm="$REALM" -s enabled=true >/dev/null
  ok "realm $REALM created"
fi

if [ -z "$(kcadm get clients -r "$REALM" -q clientId="$CLIENT_ID" --fields id --format csv --noquotes 2>/dev/null)" ]; then
  kcadm create clients -r "$REALM" \
    -s clientId="$CLIENT_ID" \
    -s protocol=openid-connect \
    -s publicClient=true \
    -s standardFlowEnabled=true \
    -s directAccessGrantsEnabled=true \
    -s 'redirectUris=["http://127.0.0.1:51327/callback","http://localhost:51327/callback"]' \
    -s 'attributes={"pkce.code.challenge.method":"S256"}' >/dev/null
  ok "public client $CLIENT_ID created (PKCE S256, loopback redirect)"
else
  ok "client $CLIENT_ID already present"
fi

# Three staff. leaver@corp.example is the one offboarded in section 6.
# firstName and lastName are not decoration: Keycloak 26 raises a
# VERIFY_PROFILE required action on an incomplete profile, which interrupts the
# authorization code flow before the daemon ever sees a code.
add_user() { # username firstName email
  if [ -z "$(kcadm get users -r "$REALM" -q username="$1" --fields id --format csv --noquotes 2>/dev/null)" ]; then
    kcadm create users -r "$REALM" -s username="$1" -s email="$3" \
      -s enabled=true -s emailVerified=true \
      -s firstName="$2" -s lastName=Corp >/dev/null
    kcadm set-password -r "$REALM" --username "$1" --new-password password >/dev/null
    ok "user $1 <$3>"
  else
    ok "user $1 already present"
  fi
}
add_user tom    Tom   tom@corp.example
add_user priya  Priya priya@corp.example
add_user leaver Alex  leaver@corp.example

# ── 3. PostgreSQL for controller state ────────────────────────────────────────
step "PostgreSQL in $AD_NS"
kc create ns "$AD_NS" --dry-run=client -o yaml | kc apply -f - >/dev/null
kc apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: { name: postgres, namespace: $AD_NS }
spec:
  replicas: 1
  selector: { matchLabels: { app: postgres } }
  template:
    metadata: { labels: { app: postgres } }
    spec:
      containers:
        - name: postgres
          image: postgres:17-alpine
          env:
            - { name: POSTGRES_USER,     value: agentdesktop }
            - { name: POSTGRES_PASSWORD, value: agentdesktop }
            - { name: POSTGRES_DB,       value: agentdesktop }
            - { name: PGDATA,            value: /var/lib/postgresql/data/pgdata }
          ports: [ { containerPort: 5432 } ]
          readinessProbe:
            exec: { command: ["pg_isready","-U","agentdesktop"] }
            initialDelaySeconds: 5
            periodSeconds: 5
          volumeMounts: [ { name: data, mountPath: /var/lib/postgresql/data } ]
      volumes: [ { name: data, emptyDir: {} } ]
---
apiVersion: v1
kind: Service
metadata: { name: postgres, namespace: $AD_NS }
spec:
  selector: { app: postgres }
  ports: [ { port: 5432, targetPort: 5432 } ]
EOF
kc -n "$AD_NS" rollout status deployment/postgres --timeout=180s >/dev/null
ok "postgres ready"

# ── 4. Controller TLS: device CA, server certificate, JWT signing key ─────────
# The daemon verifies the controller against the device CA and then enrols by
# sending a CSR, so the device private key never leaves the workstation. The
# RSA key signs the short-lived gateway JWTs the gateway validates by JWKS.
step "Controller TLS material"
if kc -n "$AD_NS" get secret agentdesktop-controller-tls >/dev/null 2>&1; then
  ok "reusing the existing device CA and signing key"
else
  W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -keyout "$W/device-ca-key.pem" -out "$W/device-ca.pem" \
    -days 30 -sha256 -subj /CN=Agentdesktop-vision-demo-device-CA \
    -addext basicConstraints=critical,CA:TRUE \
    -addext keyUsage=critical,keyCertSign,cRLSign 2>/dev/null
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
    -out "$W/gateway-jwt-key.pem" 2>/dev/null
  openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -keyout "$W/controller-key.pem" -out "$W/controller.csr" \
    -subj /CN=agentdesktop \
    -addext "subjectAltName=DNS:agentdesktop,DNS:agentdesktop.$AD_NS,DNS:agentdesktop.$AD_NS.svc,DNS:agentdesktop.$AD_NS.svc.cluster.local" \
    -addext extendedKeyUsage=serverAuth 2>/dev/null
  openssl x509 -req -in "$W/controller.csr" \
    -CA "$W/device-ca.pem" -CAkey "$W/device-ca-key.pem" \
    -set_serial 1 -days 30 -sha256 -copy_extensions copy \
    -out "$W/controller.pem" 2>/dev/null
  kc -n "$AD_NS" create secret generic agentdesktop-controller-tls \
    --from-file="$W/controller.pem" --from-file="$W/controller-key.pem" \
    --from-file="$W/device-ca.pem" --from-file="$W/device-ca-key.pem" \
    --from-file="$W/gateway-jwt-key.pem" \
    --dry-run=client -o yaml | kc apply -f - >/dev/null
  ok "device CA + controller certificate + gateway JWT key created"
fi
# The gateway needs the CA to trust the controller's JWKS endpoint.
kc -n "$AD_NS" get secret agentdesktop-controller-tls \
  -o jsonpath='{.data.device-ca\.pem}' | openssl base64 -d -A > /tmp/agentdesktop-device-ca.pem
kc -n "$AD_NS" create configmap agentdesktop-controller-ca \
  --from-file=ca.crt=/tmp/agentdesktop-device-ca.pem \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
ok "device CA published for the gateway (/tmp/agentdesktop-device-ca.pem)"

# ── 5. The controller ─────────────────────────────────────────────────────────
step "Agentdesktop controller (image tag: $CONTROLLER_IMAGE_TAG)"
GW_IP="$(kc -n "$GW_NS" get svc -l gateway.networking.k8s.io/gateway-name=ai-gateway \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
[ -n "${GW_IP:-}" ] || die "could not read the ai-gateway LoadBalancer address"

cat > /tmp/agentdesktop-values.yaml <<EOF
image:
  repository: ghcr.io/agentdesktop-dev/agentdesktop-controller
  tag: "$CONTROLLER_IMAGE_TAG"
databaseUrl: postgresql://agentdesktop:agentdesktop@postgres:5432/agentdesktop?sslmode=disable
oidc:
  issuer: $ISSUER
  clientId: $CLIENT_ID
  redirectUri: http://127.0.0.1:51327/callback
# The realm is served over plain HTTP inside this lab cluster.
allowInsecureDev: true
gatewayJwt:
  privateKey: /etc/agentdesktop/tls/gateway-jwt-key.pem
  issuer: agentdesktop-controller
  keyId: agentdesktop
  lifetime: 5m
tlsSecretName: agentdesktop-controller-tls
service:
  type: LoadBalancer
  port: 443
daemonConfig:
  llmGateway:
    url: http://$GW_IP
    authentication:
      type: controllerJwt
      audience: agentgateway
      allowedClientIds: [claude-code]
  programs:
    claudeCode:
      useLlmGateway: true
      companyAnnouncements:
        - "Managed by Agentdesktop. Model traffic goes through the corporate gateway."
  sandbox:
    filesystem:
      denied:
        - ~/.ssh
        - ~/.aws
      writable:
        - ~/src
    network:
      allowedDomains:
        - github.com
EOF
helm --kube-context "$CTX" upgrade -i agentdesktop "$CHART" \
  -n "$AD_NS" -f /tmp/agentdesktop-values.yaml >/dev/null
kc -n "$AD_NS" rollout status deployment/agentdesktop --timeout=300s >/dev/null
for _ in $(seq 1 60); do
  AD_IP="$(kc -n "$AD_NS" get svc agentdesktop -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [ -n "${AD_IP:-}" ] && break; sleep 2
done
[ -n "${AD_IP:-}" ] || die "controller LoadBalancer never received an address"
ok "controller running at $AD_IP (gateway JWT lifetime 5m)"

# ── 6. Gateway: accept only controller-minted tokens ──────────────────────────
# jwtAuthentication in Strict mode means a laptop cannot skip the daemon, and
# the Anthropic key it would need to skip the gateway is not on the laptop.
step "ai-gateway JWT policy + Anthropic /v1/messages route"
kc apply -f - >/dev/null <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: agentdesktop-jwt
  namespace: $GW_NS
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: ai-gateway
  frontend:
    accessLog:
      attributes:
        add:
          - name: llm.client
            expression: jwt.client_id
          - name: user
            expression: jwt.email
  traffic:
    jwtAuthentication:
      mode: Strict
      providers:
        - issuer: agentdesktop-controller
          audiences: [agentgateway]
          jwks:
            remote:
              jwksPath: /.well-known/jwks.json
              backendRef:
                group: ""
                kind: Service
                name: agentdesktop
                namespace: $AD_NS
                port: 443
---
# Trust the controller's self-issued certificate when fetching JWKS.
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: agentdesktop-controller-tls
  namespace: $AD_NS
spec:
  targetRefs:
    - group: ""
      kind: Service
      name: agentdesktop
  backend:
    tls:
      caCertificateRefs:
        - name: agentdesktop-controller-ca
---
# policies.ai.routes is what makes this answer Anthropic's native /v1/messages
# shape. Without it the backend normalises replies to the OpenAI schema and
# Claude Code cannot read them.
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayBackend
metadata:
  name: anthropic-claude
  namespace: $GW_NS
spec:
  ai:
    provider:
      anthropic: {}
  policies:
    auth:
      secretRef:
        name: anthropic-secret
    ai:
      routes:
        "/v1/messages": Messages
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: agentdesktop-messages
  namespace: $GW_NS
spec:
  parentRefs:
    - name: ai-gateway
  rules:
    - matches:
        - path: { type: PathPrefix, value: /v1/messages }
      backendRefs:
        - { name: anthropic-claude, group: enterpriseagentgateway.solo.io, kind: EnterpriseAgentgatewayBackend }
      timeouts: { request: 120s }
EOF
ok "gateway accepts only agentdesktop-controller tokens (aud: agentgateway)"

# ── 7. Housekeeping for a long-lived demo cluster ─────────────────────────────
# Optional, and only present in the demo driver.
if [ -x "$SCRIPT_DIR/cost-retention.sh" ] && kc -n solo-cost get pod management-clickhouse-shard0-0 >/dev/null 2>&1; then
  "$SCRIPT_DIR/cost-retention.sh" >/dev/null 2>&1 || true
fi

# ── 8. What the workstation needs ─────────────────────────────────────────────
cat > "$SCRIPT_DIR/.agentdesktop-env" <<EOF
export AD_CONTROLLER_IP=$AD_IP
export AD_KEYCLOAK_IP=$KC_IP
export AD_GATEWAY=$GW_IP
export AD_ISSUER=$ISSUER
EOF

step "Platform up"
cat <<EOF

  Controller   https://agentdesktop.$AD_NS.svc.cluster.local   ($AD_IP)
  Keycloak     http://keycloak.$KC_NS.svc.cluster.local:8080    ($KC_IP)
  ai-gateway   http://$GW_IP
  Device CA    /tmp/agentdesktop-device-ca.pem

  Add these two lines to /etc/hosts so the laptop resolves the same names the
  cluster does (the controller certificate and the OIDC issuer depend on it):

    $AD_IP agentdesktop.$AD_NS.svc.cluster.local
    $KC_IP keycloak.$KC_NS.svc.cluster.local

  Then enrol this machine:

    agentdesktop daemon --user --config demo-scripts/yaml-agentdesktop/daemon.yaml

  Sign in as tom / password. Users: tom, priya, leaver (all password 'password').

EOF
