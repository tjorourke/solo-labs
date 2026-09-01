#!/usr/bin/env bash
# 21-keycloak.sh — Keycloak (dev mode) + the `agentregistry` realm. One OIDC
# issuer for both AgentRegistry and the gateway's JWT policy on the agent
# routes. Scrapes the ar-backend confidential secret into deploy/.env.local.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

step "Namespace + realm ConfigMap"
kc create namespace "$KEYCLOAK_NS" --dry-run=client -o yaml | kc apply -f - >/dev/null
kc -n "$KEYCLOAK_NS" create configmap keycloak-realm-import \
  --from-file=agentregistry-realm.json="$LAB_ROOT/yaml/keycloak/agentregistry-realm.json" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
ok "realm import ConfigMap ready"

step "Deploying Keycloak"
kc apply -f "$LAB_ROOT/yaml/keycloak/keycloak.yaml" >/dev/null
log "waiting for Keycloak (image pull + realm import can take 1-2 min)..."
kc -n "$KEYCLOAK_NS" rollout status statefulset/keycloak --timeout=300s >/dev/null \
  || warn "keycloak not Ready in 5m — check: kubectl --context $CTX -n $KEYCLOAK_NS get pods"
ok "Keycloak up; issuer ${KEYCLOAK_ISSUER}"

step "Scraping the ar-backend client secret"
AR_BACKEND_SECRET="$(keycloak_client_secret ar-backend)"
[[ -n "$AR_BACKEND_SECRET" ]] || die "could not read the ar-backend secret from Keycloak"
mkdir -p "$LAB_ROOT/deploy"
ENVF="$LAB_ROOT/deploy/.env.local"; touch "$ENVF"
grep -vE '^AR_BACKEND_SECRET=' "$ENVF" > "$ENVF.tmp" 2>/dev/null || true
mv "$ENVF.tmp" "$ENVF"
echo "AR_BACKEND_SECRET=${AR_BACKEND_SECRET}" >> "$ENVF"
ok "ar-backend secret written to deploy/.env.local"

step "Keycloak ready"; echo "  Next: ./scripts/22-agentgateway.sh" >&2
