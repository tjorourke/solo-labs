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
# The realm `kagent` client is public, so this is a placeholder; token validation
# uses the issuer/JWKS + audience.
kc -n kagent create secret generic kagent-enterprise-oidc-secret \
  --from-literal=clientSecret="public-client-no-secret" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
ok "OIDC config ready (issuer ${KEYCLOAK_ISSUER}, clientId ${KEYCLOAK_CLIENT})"

step "Installing kagent-enterprise CRDs $KAGENT_ENT_VERSION"
helm --kube-context "$CTX" upgrade --install kagent-crds "$KENT_CRDS_CHART" \
  --namespace kagent --create-namespace --version "$KAGENT_ENT_VERSION" --wait --timeout 5m >/dev/null
ok "kagent-enterprise CRDs installed"
kc get crd agents.kagent.dev >/dev/null 2>&1 && ok "Agent CRD present" || warn "Agent CRD not found"

step "Installing kagent-enterprise controller $KAGENT_ENT_VERSION"
log "provider: anthropic; OIDC -> Keycloak; bundled postgres + tool server"
log "image pulls (controller + postgres + tools) can take several minutes"
helm_install_with_progress kagent "$KENT_CHART" kagent \
  --version "$KAGENT_ENT_VERSION" \
  --set global.licensing.licenseKey="${KAGENT_ENT_LICENSE_KEY}" \
  --set providers.default=anthropic \
  --set providers.anthropic.apiKey="${ANTHROPIC_API_KEY}" \
  --set oidc.issuer="${KEYCLOAK_ISSUER}" \
  --set oidc.clientId="${KEYCLOAK_CLIENT}" \
  --set oidc.skipOBO=false \
  --set kagent-tools.enabled=true \
  --set ui.enabled=true \
  --set-json 'rbac.roleMapping={"roleMapper":"claims.groups.transformList(i, v, v in rolesMap, rolesMap[v])","roleMappings":{"field-fte":"global.Admin","field-trial":"global.Reader","field-admin":"global.Admin","admins":"global.Admin","readers":"global.Reader","writers":"global.Writer"}}' \
  --wait --timeout 12m
# NB roleMapper uses claims.groups (lowercase) — the chart default claims.Groups
# (capital G) fails against Keycloak's lowercase `groups` claim and returns 401.
ok "kagent-enterprise controller installed"

step "Waiting for controller"
wait_deploy kagent kagent-controller 360s || warn "controller not Available in 6m — continuing"

step "kagent-enterprise installed"; echo "  Next: ./scripts/04-daemon.sh" >&2
