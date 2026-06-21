#!/usr/bin/env bash
# 03-kagent.sh — install Solo Enterprise for kagent (CRDs + controller) with
# Anthropic as the default model provider, wired to the Keycloak `solo` realm for
# OIDC. This is the runtime that hosts the agent the registry deploys.
#
# The enterprise controller runs an OIDC access-token interceptor and refuses to
# start without a discoverable issuer, so oidc.issuer points at in-cluster
# Keycloak. The role-mapper maps the token's `groups` claim to a kagent role;
# alice (field-fte) -> Admin so she can invoke agents.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_secrets
ensure_gar_auth "$GAR_HOST"

step "Namespace + OBO signing key + OIDC secret"
kc create namespace kagent --dry-run=client -o yaml | kc apply -f - >/dev/null
# RSA signing key the controller uses to mint OBO tokens; Secret MUST be named
# `jwt` in the controller namespace. Reuse on rerun so tokens stay valid.
if kc -n kagent get secret jwt >/dev/null 2>&1; then
  ok "OBO signing key Secret 'jwt' already present — keeping it"
else
  tmp="$(mktemp)"; openssl genpkey -algorithm RSA -out "$tmp" -pkeyopt rsa_keygen_bits:2048 >/dev/null 2>&1
  kc -n kagent create secret generic jwt --from-file=jwt="$tmp" >/dev/null
  rm -f "$tmp"; ok "created OBO signing key Secret 'jwt'"
fi
# kagent validates tokens against the CONFIDENTIAL kagent-backend client; its
# secret was scraped from Keycloak by 02-keycloak.sh into .env.local. Tokens are
# accepted only when their aud includes kagent-backend (the realm's audience mapper).
[[ -n "${KAGENT_BACKEND_SECRET:-}" ]] || die "KAGENT_BACKEND_SECRET not set — run ./scripts/02-keycloak.sh first"
kc -n kagent create secret generic kagent-enterprise-oidc-secret \
  --from-literal=clientSecret="${KAGENT_BACKEND_SECRET}" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
ok "OIDC config ready (issuer ${KEYCLOAK_ISSUER}, clientId ${KAGENT_BACKEND_CLIENT})"

step "Installing kagent-enterprise CRDs $KAGENT_ENT_VERSION"
helm --kube-context "$CTX" upgrade --install kagent-crds "$KENT_CRDS_CHART" \
  --namespace kagent --create-namespace --version "$KAGENT_ENT_VERSION" --wait --timeout 5m >/dev/null
ok "kagent-enterprise CRDs installed"
kc get crd agents.kagent.dev >/dev/null 2>&1 && ok "Agent CRD present" || warn "Agent CRD not found"

step "Installing kagent-enterprise controller $KAGENT_ENT_VERSION"
log "provider: anthropic; OIDC -> Keycloak; bundled postgres + tool server"
log "image pulls (controller + postgres + tools) can take several minutes"
# Drop a stale kagent-ui-config from an earlier run so helm's server-side apply
# never hits a field-manager conflict on it. No-op on a fresh install (and the OSS
# kagent UI is off — ui.enabled=false — so the ConfigMap normally isn't created).
kc -n kagent delete configmap kagent-ui-config --ignore-not-found >/dev/null 2>&1 || true
# controller.envFrom (below): kagent-enterprise#1829 — oidc.* settings land in the
# kagent-enterprise-config ConfigMap, but the controller's default envFrom doesn't
# pull it, so the pod silently runs in auto-auth and 401s the kagent UI's forwarded
# Keycloak tokens. Pulling the ConfigMap in gives the controller OIDC_ISSUER so it
# accepts them (Models/Agents/Tools pages then load).
helm_install_with_progress kagent "$KENT_CHART" kagent \
  --version "$KAGENT_ENT_VERSION" \
  --set global.licensing.licenseKey="${KAGENT_ENT_LICENSE_KEY}" \
  --set providers.default=anthropic \
  --set providers.anthropic.apiKey="${ANTHROPIC_API_KEY}" \
  --set oidc.issuer="${KEYCLOAK_ISSUER}" \
  --set oidc.clientId="${KAGENT_BACKEND_CLIENT}" \
  --set oidc.secretRef="kagent-enterprise-oidc-secret" \
  --set oidc.secretKey="clientSecret" \
  --set oidc.skipOBO=false \
  --set-json 'controller.envFrom=[{"configMapRef":{"name":"kagent-enterprise-config"}}]' \
  --set kagent-tools.enabled=true \
  --set ui.enabled=false \
  --set otel.tracing.enabled=true \
  --set otel.tracing.exporter.otlp.endpoint="${TELEMETRY_COLLECTOR_ENDPOINT}" \
  --set otel.logging.enabled=true \
  --set otel.logging.exporter.otlp.endpoint="${TELEMETRY_COLLECTOR_ENDPOINT}" \
  --set-json 'rbac.roleMapping={"roleMapper":"claims.Groups.transformList(i, v, v in rolesMap, rolesMap[v])","roleMappings":{"admins":"global.Admin","readers":"global.Reader","writers":"global.Writer"}}' \
  --timeout 12m
# OTel above makes the controller stamp OTEL_TRACING_ENABLED=true + the collector
# endpoint into every agent it deploys (default is false → no spans). Traces land
# in ClickHouse (platformdb.otel_traces_json) and render in the Enterprise UI's
# Tracing tab. The collector itself is installed next by 03b-telemetry.sh; the
# endpoint is just a string here, resolved when an agent actually exports.
# NB roleMapper uses claims.Groups (capital G) to match the agentregistry realm's
# `Groups` group-membership claim; admins -> global.Admin. (The old `solo` realm
# emitted lowercase `groups`; this realm emits `Groups`.)
# No --wait above: the controller does OIDC discovery at startup against
# keycloak.localtest.me, which a pod can't resolve until we add the hostAlias
# below — so it would never go Ready under --wait.
ok "kagent-enterprise controller applied"

step "Bridging the issuer host in-cluster, then waiting for the controller"
# Map keycloak.localtest.me -> Keycloak ClusterIP on the controller pod so OIDC
# discovery resolves. This patch also rolls the controller; then it goes Ready.
bridge_keycloak_hostalias kagent-controller
ok "hostAlias keycloak.localtest.me -> Keycloak ClusterIP added to controller"
wait_deploy kagent kagent-controller 360s || warn "controller not Available in 6m — continuing"

step "kagent-enterprise installed"; echo "  Next: ./scripts/04-agentregistry.sh" >&2
