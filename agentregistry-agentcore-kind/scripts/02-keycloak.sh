#!/usr/bin/env bash
# 02-keycloak.sh — deploy Keycloak (dev mode) and import the shared `solo` realm
# (users alice/bob/carol; alice in group field-fte; public client `kagent`).
# Enterprise kagent's controller does OIDC discovery at startup, so it needs a
# reachable issuer — this is it.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

step "Namespace + realm ConfigMap"
kc create namespace "$KEYCLOAK_NS" --dry-run=client -o yaml | kc apply -f - >/dev/null
kc -n "$KEYCLOAK_NS" create configmap keycloak-realm-import \
  --from-file=realm-solo.json="$LAB_ROOT/yaml/keycloak/realm-solo.json" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
ok "realm-solo import ConfigMap ready"

step "Deploying Keycloak"
kc apply -f "$LAB_ROOT/yaml/keycloak/keycloak.yaml" >/dev/null
log "waiting for Keycloak (image pull + realm import can take 1-2 min)..."
kc -n "$KEYCLOAK_NS" rollout status statefulset/keycloak --timeout=300s >/dev/null \
  || warn "keycloak not Ready in 5m — check: kubectl --context $CTX -n $KEYCLOAK_NS get pods"
ok "Keycloak up; issuer ${KEYCLOAK_ISSUER}"

step "Keycloak ready"; echo "  Next: ./scripts/03-kagent.sh" >&2
