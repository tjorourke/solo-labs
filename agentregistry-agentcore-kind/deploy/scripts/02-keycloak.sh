#!/usr/bin/env bash
# 02-keycloak.sh — deploy Keycloak (dev mode) and import the `agentregistry` realm
# (clients ar-backend/ar-ui/ar-cli-*/kagent-backend/kagent-ui/kagent-cli-password;
# group `admins`; user admin-user/password). This is the single OIDC issuer for
# both AgentRegistry and Solo Enterprise for kagent. After Keycloak is up we scrape
# the two confidential client secrets (ar-backend, kagent-backend) and persist them
# to .env.local so the AR (04) and kagent (03) installs can wire them.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

step "Namespace + realm ConfigMap"
kc create namespace "$KEYCLOAK_NS" --dry-run=client -o yaml | kc apply -f - >/dev/null
kc -n "$KEYCLOAK_NS" create configmap keycloak-realm-import \
  --from-file=agentregistry-realm.json="$LAB_ROOT/yaml/keycloak/agentregistry-realm.json" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
ok "agentregistry realm import ConfigMap ready"

step "Deploying Keycloak"
kc apply -f "$LAB_ROOT/yaml/keycloak/keycloak.yaml" >/dev/null
log "waiting for Keycloak (image pull + realm import can take 1-2 min)..."
kc -n "$KEYCLOAK_NS" rollout status statefulset/keycloak --timeout=300s >/dev/null \
  || warn "keycloak not Ready in 5m — check: kubectl --context $CTX -n $KEYCLOAK_NS get pods"
ok "Keycloak up; issuer ${KEYCLOAK_ISSUER}"

step "Scraping the confidential client secrets (ar-backend, kagent-backend)"
# These are PINNED in agentregistry-realm.json (a fixed "secret" per client), so
# the value survives a Keycloak restart. Keycloak has no PVC here, so on any pod
# restart it re-imports the realm; an unpinned confidential secret would be
# regenerated at random and no longer match the value baked into the AR + kagent
# installs -> the registry's kagent token mint fails "unauthorized_client" and MCP
# deploys silently fail. We still scrape (not hardcode) so the charts stay in sync
# whatever the realm holds. Persist to .env.local (gitignored, already sourced by
# load_secrets) so a later script run picks them up without re-scraping.
AR_BACKEND_SECRET="$(keycloak_client_secret ar-backend)"
KAGENT_BACKEND_SECRET="$(keycloak_client_secret kagent-backend)"
[[ -n "$AR_BACKEND_SECRET" && -n "$KAGENT_BACKEND_SECRET" ]] \
  || die "could not read client secrets from Keycloak — check the realm import"
ENVF="$LAB_ROOT/.env.local"; touch "$ENVF"
grep -vE '^(AR_BACKEND_SECRET|KAGENT_BACKEND_SECRET)=' "$ENVF" > "$ENVF.tmp" 2>/dev/null || true
mv "$ENVF.tmp" "$ENVF"
{
  echo "AR_BACKEND_SECRET=${AR_BACKEND_SECRET}"
  echo "KAGENT_BACKEND_SECRET=${KAGENT_BACKEND_SECRET}"
} >> "$ENVF"
ok "client secrets written to .env.local (ar-backend, kagent-backend)"

step "Keycloak ready"; echo "  Next: ./scripts/03-kagent.sh" >&2
