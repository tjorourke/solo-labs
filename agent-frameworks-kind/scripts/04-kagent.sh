#!/usr/bin/env bash
# 04-kagent.sh — install Solo Enterprise for kagent with OBO enabled.
#
# OBO (On-Behalf-Of) token exchange: the controller validates Alice's Keycloak
# token, then mints a kagent-SIGNED OBO token carrying her identity (sub: alice)
# plus the calling agent's ServiceAccount (act.sub: ...) for downstream hops.
# Two prerequisites:
#   1. an RSA signing key in a Secret named `jwt` in the controller namespace
#      (the controller hot-reloads it and serves JWKS at /jwks.json)
#   2. OIDC pointed at the Keycloak `solo` realm (issuer + clientId=kagent),
#      with skipOBO=false (OBO on)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_secrets
ensure_gar_auth "$GAR_HOST"

step "Namespace + OBO signing key"
kc create namespace kagent --dry-run=client -o yaml | kc apply -f - >/dev/null
# Generate the RSA signing key once; reuse it on rerun so previously-minted OBO
# tokens stay valid. Secret MUST be named `jwt` in the controller namespace.
if kc -n kagent get secret jwt >/dev/null 2>&1; then
  ok "OBO signing key Secret 'jwt' already present — keeping it"
else
  tmp="$(mktemp)"; openssl genpkey -algorithm RSA -out "$tmp" -pkeyopt rsa_keygen_bits:2048 >/dev/null 2>&1
  kc -n kagent create secret generic jwt --from-file=jwt="$tmp" >/dev/null
  rm -f "$tmp"; ok "created OBO signing key Secret 'jwt'"
fi
# OIDC client secret the chart references (the realm `kagent` client is public, so
# this is a placeholder; token validation uses the issuer/JWKS + audience).
kc -n kagent create secret generic kagent-enterprise-oidc-secret \
  --from-literal=clientSecret="public-client-no-secret" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
ok "OIDC config ready (issuer ${KEYCLOAK_ISSUER}, clientId ${KEYCLOAK_CLIENT})"

step "Installing kagent-enterprise CRDs $KAGENT_ENT_VERSION"
helm --kube-context "$CTX" upgrade --install kagent-crds "$KENT_CRDS_CHART" \
  --namespace kagent --create-namespace --version "$KAGENT_ENT_VERSION" --wait --timeout 5m >/dev/null
ok "kagent-enterprise CRDs installed"
kc get crd agentharnesses.kagent.dev accesspolicies.policy.kagent-enterprise.solo.io >/dev/null 2>&1 \
  && ok "AccessPolicy + Agent CRDs present" || warn "expected enterprise CRDs not all present"

step "Installing kagent-enterprise controller $KAGENT_ENT_VERSION"
log "OBO on (skipOBO=false); model: anthropic; bundled postgres + tool server"
log "image pulls (controller + postgres + tools) can take several min"
helm_install_with_progress kagent "$KENT_CHART" kagent \
  --version "$KAGENT_ENT_VERSION" \
  --set global.licensing.licenseKey="${KAGENT_ENT_LICENSE_KEY}" \
  --set providers.default=anthropic \
  --set providers.anthropic.apiKey="${ANTHROPIC_API_KEY}" \
  --set oidc.issuer="${KEYCLOAK_ISSUER}" \
  --set oidc.clientId="${KEYCLOAK_CLIENT}" \
  --set oidc.skipOBO=false \
  --set kagent-tools.enabled=true \
  --set-json 'rbac.roleMapping={"roleMapper":"claims.groups.transformList(i, v, v in rolesMap, rolesMap[v])","roleMappings":{"field-fte":"global.Admin","field-trial":"global.Reader","field-admin":"global.Admin","admins":"global.Admin","readers":"global.Reader","writers":"global.Writer"}}' \
  --wait --timeout 12m
# NB the roleMapper uses claims.groups (lowercase) — the chart default is
# claims.Groups (capital G), which fails with "no such key: Groups" against the
# Keycloak token's lowercase `groups` claim and returns 401. field-fte (alice)
# maps to global.Admin so she can invoke agents.
ok "kagent-enterprise controller installed"

step "Waiting for controller + tool server"
wait_deploy kagent kagent-controller 360s || warn "controller not Available in 6m — continuing"
kc -n kagent get remotemcpserver kagent-tool-server >/dev/null 2>&1 \
  && ok "kagent-tool-server present" || warn "kagent-tool-server not found — agents may not reach Ready"

step "kagent-enterprise installed"; echo "  Next: ./scripts/05-scenario.sh" >&2
