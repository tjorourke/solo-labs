#!/usr/bin/env bash
# quick.sh — orchestrator for agentregistry-governance-kind (part 2).
#   ./scripts/quick.sh up | down | status
#
# Runs ON the part-1 cluster (agentregistry-arctl-kind). `up` flips the
# registry daemon from its embedded demo IdP to the part-1 Keycloak realm and
# applies the team AccessPolicies; `down` reverts the daemon to the part-1
# auto-auth setup and removes the alias container, the NodePort, and the
# part-2 policies/artifacts.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

case "${1:-up}" in
  up)
    bash "$SCRIPT_DIR/01-registry-oidc.sh"
    bash "$SCRIPT_DIR/02-access-policies.sh"
    bash "$SCRIPT_DIR/03-publish-as-team.sh"
    ;;
  down)
    step "Removing part-2 policies and artifacts"
    as_user carol delete accesspolicy team-fte   >/dev/null 2>&1 && ok "team-fte removed"   || log "team-fte not present"
    as_user carol delete accesspolicy team-trial >/dev/null 2>&1 && ok "team-trial removed" || log "team-trial not present"
    as_user carol delete skill release-notes-style >/dev/null 2>&1 && ok "release-notes-style removed" || log "release-notes-style not present"
    step "Reverting the daemon to the part-1 auto-auth setup"
    arctl daemon stop >/dev/null 2>&1 || true
    export DOCKER_REPO="${DOCKER_REPO:-solo-public/agentregistry-enterprise}"
    export OIDC_AUTO_AUTH_ENABLED=true
    unset OIDC_ISSUER OIDC_CLIENT_ID OIDC_PUBLIC_CLIENT_ID OIDC_CLIENT_SECRET RBAC_ROLE_CLAIM RBAC_SUPERUSER_ROLE
    arctl daemon start >/dev/null 2>&1 || true
    wait_registry_healthy && ok "daemon back on the embedded demo IdP" || warn "daemon not healthy — check: docker logs $DAEMON_CONTAINER"
    step "Removing the issuer alias + NodePort"
    docker rm -f "$ALIAS_CONTAINER" >/dev/null 2>&1 && ok "alias container removed" || log "alias container not present"
    kc -n "$KEYCLOAK_NS" delete svc keycloak-nodeport >/dev/null 2>&1 && ok "NodePort removed" || log "NodePort not present"
    rm -f /tmp/agr-gov-tok-* 2>/dev/null || true
    ;;
  status)
    step "daemon"
    docker ps --filter "name=$DAEMON_CONTAINER" --format '  {{.Names}}  {{.Status}}' >&2 || true
    docker exec "$DAEMON_CONTAINER" env 2>/dev/null | grep -E '^(OIDC_ISSUER|OIDC_AUTO_AUTH_ENABLED|RBAC_ROLE_CLAIM|RBAC_SUPERUSER_ROLE)=' | sed 's/^/  /' >&2 || true
    step "policies (as carol)"
    as_user carol get accesspolicies 2>/dev/null | sed 's/^/  /' >&2 || log "carol cannot list (is part 2 up?)"
    step "the three views"
    for u in carol alice bob; do
      echo "  ── $u ──" >&2
      as_user "$u" get skills 2>&1 | sed 's/^/  /' >&2 || true
    done
    ;;
  *) echo "Usage: $0 up | down | status" >&2; exit 2;;
esac
