#!/usr/bin/env bash
# lib.sh — shared helpers for agentic-tool-privilege-kind (Keycloak + enterprise
# agentgateway + Solo Enterprise for kagent + a mock-db MCP server). Enterprise
# stack, separate kind cluster from Part 1.

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

export CLUSTER_NAME="${CLUSTER_NAME:-tool-privilege}"
export CTX="kind-${CLUSTER_NAME}"

export GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.4.0}"
export METALLB_VERSION="${METALLB_VERSION:-v0.14.9}"

# Keycloak (dev, --import-realm) — the `solo` realm. Agent identities:
#   agent-diagnoser  (group db-reader)   agent-remediator (group db-operator)
export KEYCLOAK_NS="${KEYCLOAK_NS:-keycloak}"
export KEYCLOAK_IMAGE="${KEYCLOAK_IMAGE:-quay.io/keycloak/keycloak:26.3}"
export KEYCLOAK_REALM="${KEYCLOAK_REALM:-solo}"
export KEYCLOAK_CLIENT="${KEYCLOAK_CLIENT:-kagent}"
export KEYCLOAK_ISSUER="${KEYCLOAK_ISSUER:-http://keycloak.${KEYCLOAK_NS}.svc.cluster.local/realms/${KEYCLOAK_REALM}}"

# Solo Enterprise for kagent (runs the two declarative agents).
export KAGENT_ENT_VERSION="${KAGENT_ENT_VERSION:-0.4.3}"
export KENT_CRDS_CHART="${KENT_CRDS_CHART:-oci://us-docker.pkg.dev/solo-public/kagent-enterprise-helm/charts/kagent-enterprise-crds}"
export KENT_CHART="${KENT_CHART:-oci://us-docker.pkg.dev/solo-public/kagent-enterprise-helm/charts/kagent-enterprise}"

# Enterprise agentgateway (the MCP front door doing JWT auth + per-tool authz).
export AGW_VERSION="${AGW_VERSION:-v2.3.4}"
export AGW_REGISTRY="${AGW_REGISTRY:-oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts}"
export AGW_CHART="${AGW_CHART:-${AGW_REGISTRY}/enterprise-agentgateway}"
export AGW_CRDS_CHART="${AGW_CRDS_CHART:-${AGW_REGISTRY}/enterprise-agentgateway-crds}"
export GAR_HOST="${GAR_HOST:-us-docker.pkg.dev}"

# The mock-db MCP server image (built + kind-loaded; never pulled).
export MOCK_DB_IMAGE="${MOCK_DB_IMAGE:-mock-db:dev}"

kc(){ kubectl --context "$CTX" "$@"; }
check_docker(){ docker info >/dev/null 2>&1 || die "docker daemon not reachable"; }

load_secrets() {
  if [[ -n "${SECRETS_FILE:-}" ]]; then
    [[ -f "$SECRETS_FILE" ]] || die "SECRETS_FILE='$SECRETS_FILE' does not exist"
    set -a; source "$SECRETS_FILE"; set +a
  fi
  export KAGENT_ENT_LICENSE_KEY="${KAGENT_ENT_LICENSE_KEY:-${SOLO_LICENSE_KEY:-}}"
}
require_secrets() {
  load_secrets
  local missing=()
  [[ -z "${ANTHROPIC_API_KEY:-}" ]]        && missing+=("ANTHROPIC_API_KEY")
  [[ -z "${KAGENT_ENT_LICENSE_KEY:-}" ]]   && missing+=("SOLO_LICENSE_KEY (or KAGENT_ENT_LICENSE_KEY)")
  [[ -z "${AGENTGATEWAY_LICENSE_KEY:-}" ]] && missing+=("AGENTGATEWAY_LICENSE_KEY")
  if (( ${#missing[@]} > 0 )); then
    cat >&2 <<EOF

ERROR: missing required env vars: ${missing[*]}

  export ANTHROPIC_API_KEY=sk-ant-...
  export SOLO_LICENSE_KEY=...            # Solo Enterprise for kagent
  export AGENTGATEWAY_LICENSE_KEY=...    # enterprise agentgateway
  ./scripts/quick.sh up

  or:  SECRETS_FILE=/path/to/secrets.sh ./scripts/quick.sh up
EOF
    exit 1
  fi
}

wait_deploy() {
  local ns="$1" name="$2" timeout="${3:-300s}"; local end=$(( $(date +%s) + 240 ))
  until kc -n "$ns" get deployment "$name" >/dev/null 2>&1; do
    [[ $(date +%s) -ge $end ]] && { warn "deployment $ns/$name not created in 4m"; return 1; }; sleep 3
  done
  kc -n "$ns" wait --for=condition=Available deployment/"$name" --timeout="$timeout" >/dev/null
}
wait_agent() {
  local name="$1" timeout="${2:-300}"; local end=$(( $(date +%s) + timeout ))
  until [[ "$(kc -n kagent get agent "$name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == "True" ]]; do
    [[ $(date +%s) -ge $end ]] && { warn "agent $name not Ready in ${timeout}s"; return 1; }; sleep 5
  done
}

helm_install_with_progress() {
  local release="$1" chart="$2" namespace="$3"; shift 3
  helm --kube-context "$CTX" upgrade --install "$release" "$chart" --namespace "$namespace" --create-namespace "$@" >/dev/null &
  local pid=$!; local start; start=$(date +%s)
  while kill -0 "$pid" 2>/dev/null; do
    sleep 15; kill -0 "$pid" 2>/dev/null || break
    local e=$(( $(date +%s) - start )); local p; p=$(kc -n "$namespace" get pods --no-headers 2>/dev/null | awk '{printf "%s[%s] ",$1,$2}')
    [[ -n "$p" ]] && log "[+${e}s] pods: ${p}" || log "[+${e}s] pulling images / creating pods..."
  done
  wait "$pid"
}

ensure_gar_auth() {
  local host="${1:-$GAR_HOST}"
  command -v gcloud >/dev/null 2>&1 || die "gcloud required for the Solo enterprise charts ($host)."
  if ! gcloud auth print-access-token >/dev/null 2>&1; then
    [[ -t 0 ]] || die "gcloud not authenticated and no TTY. Run: gcloud auth login"
    gcloud auth login || die "gcloud auth login failed"
  fi
  gcloud auth print-access-token | helm registry login -u oauth2accesstoken --password-stdin "$host" >/dev/null \
    || die "helm registry login failed for $host"
}

build_and_load() {
  local dir="$1" image="$2"
  docker build -t "$image" "$dir" >/dev/null
  kind load docker-image "$image" --name "$CLUSTER_NAME" >/dev/null
}

decode_jwt() {
  local t="${1:-$(cat)}"
  printf '%s' "$t" | cut -d. -f2 | tr '_-' '/+' | { cat; printf '=='; } | base64 -d 2>/dev/null | python3 -m json.tool 2>/dev/null
}

# mint_keycloak_token <user> — password grant (password = username), print raw token.
mint_keycloak_token() {
  local user="$1" pass="${2:-$1}"
  kc -n "$KEYCLOAK_NS" port-forward svc/keycloak 18080:80 >/tmp/kc-pf.$$ 2>&1 & local pf=$!
  local tok=""
  for _ in $(seq 1 30); do curl -s -o /dev/null "http://localhost:18080/realms/${KEYCLOAK_REALM}/.well-known/openid-configuration" && break; sleep 1; done
  tok="$(curl -s -X POST "http://localhost:18080/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d "grant_type=password&client_id=${KEYCLOAK_CLIENT}&username=${user}&password=${pass}" \
    | python3 -c 'import json,sys;print(json.load(sys.stdin).get("access_token",""))')"
  kill "$pf" 2>/dev/null
  printf '%s' "$tok"
}
