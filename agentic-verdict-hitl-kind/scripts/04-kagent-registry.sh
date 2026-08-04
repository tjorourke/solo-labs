#!/usr/bin/env bash
# 04-kagent-registry.sh — Solo Enterprise for kagent + Enterprise AgentRegistry
# + Kyverno.
#
# Kyverno is installed here rather than later because it is a platform-team
# component, not a demo prop: it is the admission webhook that lets the platform
# team rewrite an agent it does not own. Phase 07 applies the actual policy.
#
# Both charts install against the same Keycloak realm. The kagent chart takes
# several minutes on a cold cluster, so it runs in the background while the
# registry chart applies, then both are waited on.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_secrets
gar_login

[[ -n "${LB:-}" ]] || die "LB not set — run ./scripts/02-agentgateway.sh first"
[[ -f "$LAB_ROOT/.env.oidc" ]] || die ".env.oidc missing — run ./scripts/03-keycloak.sh first"
# shellcheck disable=SC1091
set -a; . "$LAB_ROOT/.env.oidc"; set +a

# ── kagent Enterprise ─────────────────────────────────────────────────────────
step "Installing Solo Enterprise for kagent ${KAGENT_ENT_VERSION}"

# The controller signs on-behalf-of tokens with this key. Generated once and
# kept; a re-run reuses it so existing sessions stay valid.
kc -n "$KAGENT_NS" get secret jwt >/dev/null 2>&1 || {
  t="$(mktemp)"
  openssl genpkey -algorithm RSA -out "$t" -pkeyopt rsa_keygen_bits:2048 >/dev/null 2>&1
  kc -n "$KAGENT_NS" create secret generic jwt --from-file=jwt="$t" >/dev/null
  rm -f "$t"
  ok "generated the OBO signing key (secret/jwt)"
}

kc -n "$KAGENT_NS" create secret generic kagent-enterprise-oidc-secret \
  --from-literal=clientSecret="$KAGENT_BACKEND_SECRET" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null

# The model key both agents use, and the same Secret the chart's default
# ModelConfig references.
#
# The chart defaults are already providers.anthropic.apiKeySecretRef=kagent-anthropic
# and apiKeySecretKey=ANTHROPIC_API_KEY, so creating the Secret here is all that is
# needed. Do NOT also pass --set providers.anthropic.apiKey: that makes the chart
# try to CREATE this Secret, and Helm then refuses the whole install with
# "exists and cannot be imported into the current release: invalid ownership
# metadata". One Secret, created here, referenced by both the chart and Kyverno.
kc -n "$KAGENT_NS" create secret generic kagent-anthropic \
  --from-literal=ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
ok "model key stored in secret/kagent-anthropic"

helm --kube-context "$CTX" upgrade --install kagent-crds "$KENT_CRDS_CHART" \
  -n "$KAGENT_NS" --create-namespace --version "$KAGENT_ENT_VERSION" \
  --wait --timeout 5m >/dev/null
ok "kagent CRDs installed"

# The UI ConfigMap is immutable across some chart upgrades; drop it so a re-run
# does not fail on an unchangeable field.
kc -n "$KAGENT_NS" delete configmap kagent-ui-config --ignore-not-found >/dev/null 2>&1 || true

helm --kube-context "$CTX" upgrade --install kagent "$KENT_CHART" \
  -n "$KAGENT_NS" --version "$KAGENT_ENT_VERSION" \
  --set global.licensing.licenseKey="$SOLO_LICENSE_KEY" \
  --set providers.default=anthropic \
  --set oidc.issuer="$KEYCLOAK_ISSUER" \
  --set oidc.clientId="$KAGENT_BACKEND_CLIENT" \
  --set oidc.secretRef=kagent-enterprise-oidc-secret \
  --set oidc.secretKey=clientSecret \
  --set oidc.skipOBO=false \
  --set kagent-tools.enabled=true \
  --set ui.enabled=true \
  --set-json 'rbac.roleMapping={"roleMapper":"claims.Groups.transformList(i, v, v in rolesMap, rolesMap[v])","roleMappings":{"admins":"global.Admin","readers":"global.Reader","writers":"global.Writer"}}' \
  --timeout 12m >/dev/null &
KAGENT_PID=$!
log "kagent chart applying in the background…"

# ── Enterprise AgentRegistry ──────────────────────────────────────────────────
step "Installing Enterprise AgentRegistry ${AR_VERSION} in ${AR_NS}"
helm --kube-context "$CTX" upgrade --install agentregistry "$AR_CHART" \
  -n "$AR_NS" --create-namespace --version "$AR_VERSION" \
  --set oidc.issuer="$KEYCLOAK_ISSUER" \
  --set oidc.clientId="$AR_BACKEND_CLIENT" \
  --set oidc.clientSecret="$AR_BACKEND_SECRET" \
  --set oidc.publicClientId="$AR_UI_CLIENT" \
  --set oidc.roleClaim=Groups \
  --set oidc.superuserRole="$RBAC_SUPERUSER_ROLE" \
  --set kagent.outboundAuth.oidc.clientId="$KAGENT_BACKEND_CLIENT" \
  --set kagent.outboundAuth.oidc.clientSecret="$KAGENT_BACKEND_SECRET" \
  --set database.postgres.type=bundled >/dev/null
ok "AgentRegistry chart applied"

step "Waiting for both control planes + wiring the issuer hostAlias"
wait "$KAGENT_PID" 2>/dev/null || true
ok "kagent chart applied"

# Both in-cluster consumers must resolve the sslip issuer hostname. See bridge()
# in lib.sh for why this is a hostAlias and not a second issuer string.
bridge kagent-controller "$KAGENT_NS" && ok "hostAlias on kagent-controller"
for _ in $(seq 1 30); do
  kc -n "$AR_NS" get deploy "$AR_SERVER_SVC" >/dev/null 2>&1 && break
  sleep 3
done
bridge "$AR_SERVER_SVC" "$AR_NS" && ok "hostAlias on ${AR_SERVER_SVC}"

kc -n "$KAGENT_NS" rollout status deploy/kagent-controller --timeout=360s >/dev/null 2>&1 \
  && ok "kagent controller Ready" || warn "kagent controller not Ready yet"
kc -n "$AR_NS" rollout status deploy/"$AR_SERVER_SVC" --timeout=360s >/dev/null 2>&1 \
  && ok "AgentRegistry server Ready" || warn "AgentRegistry server not Ready yet"

# ── Kyverno ───────────────────────────────────────────────────────────────────
# The platform team's admission webhook. Phase 07 applies the policies; this
# just makes the machinery available.
step "Installing Kyverno ${KYVERNO_VERSION}"
if kc -n kyverno get deploy kyverno-admission-controller >/dev/null 2>&1; then
  ok "Kyverno already installed"
else
  kc apply --server-side --force-conflicts \
    -f "https://github.com/kyverno/kyverno/releases/download/${KYVERNO_VERSION}/install.yaml" >/dev/null
  ok "Kyverno manifests applied"
fi
kc -n kyverno rollout status deploy/kyverno-admission-controller --timeout=240s >/dev/null 2>&1 \
  && ok "Kyverno admission controller Ready" || warn "Kyverno not Ready yet"
kc wait --for=condition=Established crd/clusterpolicies.kyverno.io --timeout=60s >/dev/null 2>&1 || true

# Bootstrap both ConfigMaps the verdict policy reads, so its context can never
# resolve against a missing object. Phase 07 overwrites them with real values.
# Created empty-and-green here so nothing is gated before a review has happened.
kc -n kyverno create configmap agent-risk-register \
  --from-literal=red="" --from-literal=default="green" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
kc -n kyverno create configmap agent-platform-config \
  --from-literal=gatedMcpUrl="http://mcp.${LB:-invalid}.sslip.io/mcp-gated" \
  --from-literal=restrictedLlmUrl="http://llm.${LB:-invalid}.sslip.io" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
ok "risk register + platform config bootstrapped (nothing gated yet)"

# ── model-key injection ───────────────────────────────────────────────────────
# Applied here rather than in phase 07 because it is infrastructure, not part of
# the verdict story: without it every agent deploys keyless and fails at first
# prompt with a missing-API-key error. Retried because Kyverno's own validating
# webhook can 500 for a few seconds after the CRD lands, and a single attempt
# silently loses the whole policy.
step "Kyverno model-key injection policy"
KPOL_ERR=""
for _ in $(seq 1 12); do
  KPOL_ERR="$(kc apply -f "$LAB_ROOT/yaml/kyverno/10-inject-model-key.yaml" 2>&1)" && break
  sleep 5
done
if kc get clusterpolicy inject-agent-model-key >/dev/null 2>&1; then
  kc wait --for=condition=Ready clusterpolicy/inject-agent-model-key --timeout=60s >/dev/null 2>&1 || true
  ok "model-key injection active (agents deploy keyless)"
else
  die "model-key policy failed to apply — agents would be keyless: ${KPOL_ERR}"
fi

step "Platform ready"
echo "  AgentRegistry: ${ARCTL_API_BASE_URL}" >&2
echo "  Next:          ./scripts/05-mcp-and-hitl.sh" >&2
