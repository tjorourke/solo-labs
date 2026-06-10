#!/usr/bin/env bash
# lib.sh — shared helpers for agentregistry-governance-kind (part 2).
#
# Story: part 1 (agentregistry-arctl-kind) left a kind cluster running with
# Keycloak (realm `solo`), Solo Enterprise for kagent, and the AgentRegistry
# enterprise daemon on localhost:12121 using its embedded demo IdP. Part 2 puts
# the registry behind the SAME Keycloak realm, maps the token `groups` claim to
# registry roles (carol/field-admin = superuser), and partitions the catalog
# per team with AccessPolicies.

set -Eeuo pipefail

__has_color() { [[ -t 2 ]] && command -v tput >/dev/null 2>&1; }
if __has_color; then
  __dim(){ tput dim;printf '%s' "$*";tput sgr0;}; __ok(){ tput setaf 2;printf '✓ ';tput sgr0;printf '%s' "$*";}
  __warn(){ tput setaf 3;printf '! ';tput sgr0;printf '%s' "$*";}; __err(){ tput setaf 1;printf 'ERROR: ';tput sgr0;printf '%s' "$*";}
  __step(){ tput bold;printf '%s' "$*";tput sgr0;}
else
  __dim(){ printf '%s' "$*";}; __ok(){ printf '✓ %s' "$*";}; __warn(){ printf '! %s' "$*";}; __err(){ printf 'ERROR: %s' "$*";}; __step(){ printf '%s' "$*";}
fi
log(){ { __dim "  $*";printf '\n';} >&2; }
ok(){ { __ok "$*";printf '\n';} >&2; }
warn(){ { __warn "$*";printf '\n';} >&2; }
die(){ { __err "$*";printf '\n';} >&2; exit 1; }
step(){ printf '\n' >&2; { __step "══> $*";printf '\n';} >&2; }
require(){ command -v "$1" >/dev/null 2>&1 || die "$1 not found — install it first"; }

# ── the part-1 cluster ───────────────────────────────────────────────────────
export CLUSTER_NAME="${CLUSTER_NAME:-arctl-lab}"
export CTX="kind-${CLUSTER_NAME}"
export KEYCLOAK_NS="${KEYCLOAK_NS:-keycloak}"
export KEYCLOAK_REALM="${KEYCLOAK_REALM:-solo}"
export KEYCLOAK_CLIENT="${KEYCLOAK_CLIENT:-kagent}"
# The issuer as the daemon container will see it. Must match the token `iss`
# (Keycloak's KC_HOSTNAME pins it to the in-cluster service hostname).
export KEYCLOAK_ISSUER="${KEYCLOAK_ISSUER:-http://keycloak.${KEYCLOAK_NS}.svc.cluster.local/realms/${KEYCLOAK_REALM}}"
export KEYCLOAK_NODEPORT="${KEYCLOAK_NODEPORT:-30080}"

# ── the registry daemon ──────────────────────────────────────────────────────
export ARCTL_API_BASE_URL="${ARCTL_API_BASE_URL:-http://localhost:12121}"
export DAEMON_CONTAINER="agentregistry-enterprise-server"
export DAEMON_NETWORK="agentregistry_agentregistry-network"
export ALIAS_CONTAINER="arctl-keycloak-alias"

kc(){ kubectl --context "$CTX" "$@"; }
check_docker(){ docker info >/dev/null 2>&1 || die "docker daemon not reachable"; }

# decode_jwt — print a JWT payload (2nd segment) as pretty JSON. Reads $1 or stdin.
decode_jwt() {
  local t="${1:-$(cat)}"
  printf '%s' "$t" | cut -d. -f2 | tr '_-' '/+' | { cat; printf '=='; } | base64 -d 2>/dev/null | python3 -m json.tool 2>/dev/null
}

# mint_token <user> — password-grant a Keycloak token for alice/bob/carol via a
# short-lived port-forward, print it on stdout.
mint_token() {
  local user="$1" tok pf
  kc -n "$KEYCLOAK_NS" port-forward svc/keycloak 18080:80 >/dev/null 2>&1 & pf=$!
  for _ in $(seq 1 30); do
    curl -s -o /dev/null "http://localhost:18080/realms/${KEYCLOAK_REALM}/.well-known/openid-configuration" && break; sleep 1
  done
  tok="$(curl -s -X POST "http://localhost:18080/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d "grant_type=password&client_id=${KEYCLOAK_CLIENT}&username=${user}&password=${user}" \
    | python3 -c 'import json,sys;print(json.load(sys.stdin).get("access_token",""))')"
  kill "$pf" 2>/dev/null || true
  [[ -n "$tok" ]] || die "could not mint a token for ${user} (is Keycloak up?)"
  printf '%s' "$tok"
}

# as_user <user> <arctl args...> — run arctl with <user>'s bearer.
as_user() {
  local user="$1"; shift
  local cache="/tmp/agr-gov-tok-${user}"
  # Reuse a cached token while it is still fresh (<25 min old).
  if [[ ! -f "$cache" || -n "$(find "$cache" -mmin +25 2>/dev/null)" ]]; then
    mint_token "$user" > "$cache"
  fi
  arctl --registry-token "$(cat "$cache")" "$@"
}

wait_registry_healthy() {
  local end=$(( $(date +%s) + 180 ))
  until [[ "$(docker inspect -f '{{.State.Health.Status}}' "$DAEMON_CONTAINER" 2>/dev/null)" == "healthy" ]]; do
    [[ $(date +%s) -ge $end ]] && return 1; sleep 3
  done
}
