#!/usr/bin/env bash
# 04-kagent.sh — install Solo Enterprise for kagent (controller + bundled tool
# server), wired to Anthropic. This lab does not use kagent OIDC/OBO — the agents'
# identity toward the MCP layer is the Keycloak token their RemoteMCPServer
# injects, not a kagent-signed OBO token. kagent just runs the two agents.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_secrets
ensure_gar_auth "$GAR_HOST"

step "Namespace"
kc create namespace kagent --dry-run=client -o yaml | kc apply -f - >/dev/null

step "Installing kagent-enterprise CRDs $KAGENT_ENT_VERSION"
helm --kube-context "$CTX" upgrade --install kagent-crds "$KENT_CRDS_CHART" \
  --namespace kagent --create-namespace --version "$KAGENT_ENT_VERSION" --wait --timeout 5m >/dev/null
ok "kagent-enterprise CRDs installed"

# The enterprise controller initialises an OIDC access-token interceptor at
# startup and defaults its issuer to the solo-enterprise-ui service (not installed
# here), which makes it crashloop on OIDC discovery. Point it at Keycloak (which IS
# up) so discovery succeeds. OBO stays on (its default), so the controller needs an
# RSA signing key Secret named `jwt`; the group->role mapper uses the lowercase
# `groups` claim (the chart default `claims.Groups` fails against Keycloak tokens).
# This lab does not exercise OBO itself — the agent identity toward the MCP layer is
# the injected Keycloak token — but the enterprise controller wants it configured.
kc -n kagent create secret generic kagent-enterprise-oidc-secret \
  --from-literal=clientSecret="public-client-no-secret" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
if ! kc -n kagent get secret jwt >/dev/null 2>&1; then
  __k="$(mktemp)"; openssl genpkey -algorithm RSA -out "$__k" -pkeyopt rsa_keygen_bits:2048 >/dev/null 2>&1
  kc -n kagent create secret generic jwt --from-file=jwt="$__k" >/dev/null; rm -f "$__k"
  ok "created OBO signing key Secret 'jwt'"
else
  ok "OBO signing key Secret 'jwt' already present"
fi

step "Installing kagent-enterprise controller $KAGENT_ENT_VERSION (Anthropic + Keycloak OIDC)"
log "image pulls (controller + bundled postgres + tools) can take several minutes"
helm_install_with_progress kagent "$KENT_CHART" kagent \
  --version "$KAGENT_ENT_VERSION" \
  --set global.licensing.licenseKey="${KAGENT_ENT_LICENSE_KEY}" \
  --set providers.default=anthropic \
  --set providers.anthropic.apiKey="${ANTHROPIC_API_KEY}" \
  --set oidc.issuer="${KEYCLOAK_ISSUER}" \
  --set oidc.clientId="${KEYCLOAK_CLIENT}" \
  --set kagent-tools.enabled=true \
  --set-json 'rbac.roleMapping={"roleMapper":"claims.groups.transformList(i, v, v in rolesMap, rolesMap[v])","roleMappings":{"db-reader":"global.Admin","db-operator":"global.Admin","field-fte":"global.Admin","field-admin":"global.Admin"}}' \
  --wait --timeout 12m
ok "kagent-enterprise controller installed"

step "Waiting for controller"
wait_deploy kagent kagent-controller 360s || warn "controller not Available in 6m — continuing"
kc -n kagent get modelconfig default-model-config >/dev/null 2>&1 \
  && ok "default-model-config present" || warn "default-model-config not created — check providers values"

step "kagent-enterprise installed"; echo "  Next: ./scripts/05-mcp-and-gateway.sh" >&2
