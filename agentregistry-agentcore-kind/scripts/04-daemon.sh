#!/usr/bin/env bash
# 04-daemon.sh — start the local AgentRegistry daemon (Docker Compose,
# localhost:12121) and mint a bearer token for arctl. The daemon is the catalog
# and the control plane: artifacts are published to it and a Runtime points it
# at the kind cluster.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

step "Starting the arctl daemon"
# The enterprise arctl daemon's compose pulls its server image from
# ${DOCKER_REGISTRY}/${DOCKER_REPO}/server and defaults to an in-cluster Keycloak
# for OIDC. For a standalone local control plane we point DOCKER_REPO at the
# public GA mirror and switch on the embedded auto-auth IDP (so no external
# Keycloak is needed — `arctl_token` then mints an admin bearer against it).
export DOCKER_REPO="${DOCKER_REPO:-solo-public/agentregistry-enterprise}"
export OIDC_AUTO_AUTH_ENABLED="${OIDC_AUTO_AUTH_ENABLED:-true}"
# Check the actual API, not `arctl daemon status` — status can report a stale
# "running" from a previous Docker context (e.g. after switching Docker Desktop
# <-> OrbStack) while nothing is actually serving on :12121. If the API is down,
# clear any stale state and start fresh.
if curl -sf -m3 "${ARCTL_API_BASE_URL}/" >/dev/null 2>&1 || curl -sf -m3 "${ARCTL_API_BASE_URL}/v0/version" >/dev/null 2>&1; then
  ok "daemon already serving on ${ARCTL_API_BASE_URL}"
else
  arctl daemon stop >/dev/null 2>&1 || true   # clear stale state from a prior context
  arctl daemon start >/dev/null 2>&1 || die "arctl daemon start failed (is Docker running? can you pull ${DOCKER_REGISTRY:-us-docker.pkg.dev}/${DOCKER_REPO}/server?)"
  ok "daemon started (auto-auth IDP, server image ${DOCKER_REPO}/server)"
fi

step "Waiting for the registry API on ${ARCTL_API_BASE_URL}"
end=$(( $(date +%s) + 90 ))
until curl -sf "${ARCTL_API_BASE_URL}/v0/version" >/dev/null 2>&1 || curl -sf "${ARCTL_API_BASE_URL}/" >/dev/null 2>&1; do
  [[ $(date +%s) -ge $end ]] && die "registry API did not come up in 90s"; sleep 2
done
ok "registry API reachable"

step "Authenticating arctl"
arctl_token
if [[ -n "${ARCTL_API_TOKEN:-}" ]]; then
  ok "minted demo-auth token (ARCTL_API_TOKEN set)"
  arctl user whoami 2>/dev/null | sed 's/^/  /' >&2 || true
else
  log "no demo-auth token issued — assuming the daemon needs no auth"
fi
arctl get runtimes >/dev/null 2>&1 && ok "arctl can talk to the registry" || warn "arctl get runtimes failed"

step "Daemon ready"; echo "  Next: ./scripts/05-scaffold.sh" >&2
