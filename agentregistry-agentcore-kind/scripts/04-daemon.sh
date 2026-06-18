#!/usr/bin/env bash
# 04-daemon.sh — start the AgentRegistry enterprise daemon (Docker Compose,
# localhost:12121) behind the SAME Keycloak as kagent. One user token (alice)
# then authenticates arctl AND is forwarded to the kagent controller on deploy,
# so the kagent platform shows in the AR UI with live instances.
#
# The daemon is a Docker container; to validate Keycloak bearers it does OIDC
# discovery at OIDC_ISSUER (keycloak.localtest.me:18080), which it must resolve
# and reach from Docker. Two pieces make that work on a laptop:
#   1. NodePorts on the kind node: Keycloak (for the daemon's discovery) and the
#      kagent controller (the Kagent runtime's kagentUrl).
#   2. a socat container whose Docker network-alias IS the issuer host
#      (keycloak.localtest.me), forwarding :18080 -> node:KEYCLOAK_NODEPORT,
#      joined to the kind network AND the daemon's compose network.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

step "Exposing Keycloak + the kagent controller on the kind node (NodePorts)"
kc apply -f "$LAB_ROOT/yaml/node-ports.yaml" >/dev/null
ok "NodePorts: keycloak ${KEYCLOAK_NODEPORT}, kagent-controller ${CONTROLLER_NODEPORT}"

step "Issuer alias on the Docker side (keycloak.localtest.me -> node:${KEYCLOAK_NODEPORT})"
if [[ "$(docker inspect -f '{{.State.Running}}' "$ALIAS_CONTAINER" 2>/dev/null)" != "true" ]]; then
  docker rm -f "$ALIAS_CONTAINER" >/dev/null 2>&1 || true
  docker run -d --name "$ALIAS_CONTAINER" --restart=always \
    --network kind --network-alias keycloak.localtest.me \
    alpine/socat TCP-LISTEN:18080,fork,reuseaddr "TCP:${CLUSTER_NAME}-control-plane:${KEYCLOAK_NODEPORT}" >/dev/null
fi
ok "'$ALIAS_CONTAINER' aliases keycloak.localtest.me on the kind network"

step "Starting the daemon behind Keycloak"
# The compose interpolates these host env vars. Auto-auth OFF; validate Keycloak
# bearers; map the `groups` claim and treat field-fte as the registry superuser.
export DOCKER_REPO="${DOCKER_REPO:-solo-public/agentregistry-enterprise}"
export OIDC_AUTO_AUTH_ENABLED=false
export OIDC_ISSUER="$KEYCLOAK_ISSUER"
export OIDC_CLIENT_ID="$KEYCLOAK_CLIENT"
export OIDC_PUBLIC_CLIENT_ID="$KEYCLOAK_CLIENT"
export OIDC_CLIENT_SECRET="public-client-no-secret"
export RBAC_ROLE_CLAIM=groups
arctl daemon stop >/dev/null 2>&1 || true; sleep 2
arctl daemon start >/dev/null 2>&1 || true   # crash-loops until the alias is on its compose network (next step)
ok "daemon starting (issuer ${KEYCLOAK_ISSUER}, role claim 'groups', superuser '${RBAC_SUPERUSER_ROLE}')"

step "Wiring the daemon's networks"
# The compose network exists only after start: give it the issuer alias so OIDC
# discovery resolves, and join the daemon to the kind network so it can reach the
# kagent controller NodePort (the Kagent runtime's kagentUrl).
docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' "$ALIAS_CONTAINER" 2>/dev/null | grep -qx "$DAEMON_NETWORK" \
  || docker network connect --alias keycloak.localtest.me "$DAEMON_NETWORK" "$ALIAS_CONTAINER" >/dev/null 2>&1 || true
docker network connect kind "$DAEMON_CONTAINER" >/dev/null 2>&1 || true
docker restart "$DAEMON_CONTAINER" >/dev/null 2>&1 || true   # skip the crash-loop backoff

step "Waiting for the registry to be healthy"
end=$(( $(date +%s) + 180 ))
until [[ "$(docker inspect -f '{{.State.Health.Status}}' "$DAEMON_CONTAINER" 2>/dev/null)" == "healthy" ]]; do
  [[ $(date +%s) -ge $end ]] && die "registry not healthy in 3m — check: docker logs $DAEMON_CONTAINER"; sleep 3
done
ok "registry healthy on ${ARCTL_API_BASE_URL}, validating Keycloak bearers"

step "Authenticating arctl as ${AS_USER:-alice}"
arctl_token
[[ -n "${ARCTL_API_TOKEN:-}" ]] || die "could not mint ${AS_USER:-alice}'s Keycloak token (is Keycloak up?)"
arctl get runtimes >/dev/null 2>&1 && ok "${AS_USER:-alice} can talk to the registry" || warn "arctl get runtimes failed"
step "Daemon ready"; echo "  Next: ./scripts/04b-register-runtime.sh" >&2
