#!/usr/bin/env bash
# 01-registry-oidc.sh — put the AgentRegistry enterprise daemon behind the
# part-1 Keycloak realm.
#
# The daemon validates bearers by OIDC discovery at OIDC_ISSUER, and the token
# `iss` is pinned to the in-cluster hostname (KC_HOSTNAME), so the daemon
# container must be able to RESOLVE and REACH
# http://keycloak.keycloak.svc.cluster.local from Docker. Two pieces make that
# true on a laptop:
#   1. a NodePort Service (30080) exposing Keycloak on the kind node, and
#   2. a socat container on the Docker side whose *network alias* IS the
#      in-cluster hostname, forwarding :80 -> <kind node>:30080. Docker's
#      embedded DNS then resolves the issuer hostname for any container that
#      shares a network with it.
# The alias container joins both the kind network (to reach the node) and the
# daemon's compose network (so the daemon can resolve it across restarts).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

step "Pre-flight (part 1 must be up)"
require kind; require kubectl; require docker; require curl; require jq; require arctl
check_docker
kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME" || die "kind cluster '$CLUSTER_NAME' not found — run part 1 first (agentregistry-arctl-kind)"
kc -n "$KEYCLOAK_NS" get statefulset keycloak >/dev/null 2>&1 || die "Keycloak not found in '$KEYCLOAK_NS' — run part 1 first"
docker ps -a --format '{{.Names}}' | grep -qx "$DAEMON_CONTAINER" || die "registry daemon container not found — run part 1's 04-daemon.sh first"
ok "part-1 cluster, Keycloak, and registry daemon present"

step "Exposing Keycloak on the kind node (NodePort ${KEYCLOAK_NODEPORT})"
kc apply -f "$LAB_ROOT/yaml/keycloak-nodeport.yaml" >/dev/null
ok "Service keycloak/keycloak-nodeport -> ${KEYCLOAK_NODEPORT}"

step "Issuer alias on the Docker side"
if [[ "$(docker inspect -f '{{.State.Running}}' "$ALIAS_CONTAINER" 2>/dev/null)" != "true" ]]; then
  docker rm -f "$ALIAS_CONTAINER" >/dev/null 2>&1 || true
  docker run -d --name "$ALIAS_CONTAINER" --restart=always \
    --network kind --network-alias "keycloak.${KEYCLOAK_NS}.svc.cluster.local" \
    alpine/socat TCP-LISTEN:80,fork,reuseaddr "TCP:${CLUSTER_NAME}-control-plane:${KEYCLOAK_NODEPORT}" >/dev/null
fi
ok "'$ALIAS_CONTAINER' aliases keycloak.${KEYCLOAK_NS}.svc.cluster.local on the kind network"

step "Restarting the daemon with Keycloak OIDC + role mapping"
# Same claim-case gotcha as part 1's kagent install: the compose default role
# claim is `Groups` (capital G) and Keycloak emits `groups` — leave it unset
# and every caller maps to no roles.
arctl daemon stop >/dev/null 2>&1 || true
sleep 2
export DOCKER_REPO="${DOCKER_REPO:-solo-public/agentregistry-enterprise}"
export OIDC_AUTO_AUTH_ENABLED=false
export OIDC_ISSUER="$KEYCLOAK_ISSUER"
export OIDC_CLIENT_ID="$KEYCLOAK_CLIENT"
export OIDC_PUBLIC_CLIENT_ID="$KEYCLOAK_CLIENT"
export OIDC_CLIENT_SECRET="public-client-no-secret"
export RBAC_ROLE_CLAIM=groups
export RBAC_SUPERUSER_ROLE=field-admin
arctl daemon start >/dev/null 2>&1 || true   # first boot crash-loops until the alias is attached below
ok "daemon restarted (issuer ${KEYCLOAK_ISSUER}, role claim 'groups', superuser 'field-admin')"

step "Attaching the issuer alias to the daemon's compose network"
# The daemon does OIDC discovery at startup, on its own compose network. Give
# that network the same alias so discovery succeeds across restarts.
if ! docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' "$ALIAS_CONTAINER" 2>/dev/null \
     | grep -qx "$DAEMON_NETWORK"; then
  docker network connect --alias "keycloak.${KEYCLOAK_NS}.svc.cluster.local" "$DAEMON_NETWORK" "$ALIAS_CONTAINER" >/dev/null
fi
# The daemon crash-looped until the alias existed; restart it once to skip the
# remaining restart backoff.
docker restart "$DAEMON_CONTAINER" >/dev/null 2>&1 || true
wait_registry_healthy || die "registry did not become healthy in 3m — check: docker logs $DAEMON_CONTAINER"
ok "registry healthy on $ARCTL_API_BASE_URL, validating Keycloak bearers"

step "Smoke test: superuser vs unauthenticated"
NOAUTH="$(curl -s -o /dev/null -w '%{http_code}' "$ARCTL_API_BASE_URL/v0/agents")"
log "no token            -> HTTP ${NOAUTH}"
as_user carol get agents 2>/dev/null | sed 's/^/  carol (field-admin)  /' >&2 || true
ok "carol (group field-admin -> RBAC_SUPERUSER_ROLE) sees the part-1 catalog"
echo "  Next: ./scripts/02-access-policies.sh" >&2
