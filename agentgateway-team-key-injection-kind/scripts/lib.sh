#!/usr/bin/env bash
# lib.sh — shared helpers for agentgateway-team-key-injection-kind.
#
# Same cluster + AGW install shape as the guardrail labs. This lab needs only an
# Enterprise AGW license (jwtAuthentication + transformation are Enterprise
# fields); the "team keys" are demo strings, so no real provider key is required.

set -Eeuo pipefail

__versions_env="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/versions.env"
[ -f "$__versions_env" ] && . "$__versions_env"
: "${AGW_ENT_VERSION:=v2.3.4}"

__has_color() { [[ -t 2 ]] && command -v tput >/dev/null 2>&1; }
if __has_color; then
  __dim()  { tput dim;  printf '%s' "$*"; tput sgr0; }
  __ok()   { tput setaf 2; printf '✓ '; tput sgr0; printf '%s' "$*"; }
  __warn() { tput setaf 3; printf '! '; tput sgr0; printf '%s' "$*"; }
  __err()  { tput setaf 1; printf 'ERROR: '; tput sgr0; printf '%s' "$*"; }
  __step() { tput bold; printf '%s' "$*"; tput sgr0; }
else
  __dim()  { printf '%s' "$*"; }; __ok() { printf '✓ %s' "$*"; }
  __warn() { printf '! %s' "$*"; }; __err() { printf 'ERROR: %s' "$*"; }
  __step() { printf '%s' "$*"; }
fi
log()  { { __dim "  $*"; printf '\n'; } >&2; }
ok()   { { __ok "$*";    printf '\n'; } >&2; }
warn() { { __warn "$*";  printf '\n'; } >&2; }
die()  { { __err "$*";   printf '\n'; } >&2; exit 1; }
step() { printf '\n' >&2; { __step "══> $*"; printf '\n'; } >&2; }

require() { command -v "$1" >/dev/null 2>&1 || die "$1 not found — install it first"; }

export CLUSTER_NAME="${CLUSTER_NAME:-teamkey}"
export CTX="kind-${CLUSTER_NAME}"

export AGW_VERSION="${AGW_VERSION:-$AGW_ENT_VERSION}"
export AGW_REGISTRY="${AGW_REGISTRY:-oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts}"
export AGW_GAR_HOST="${AGW_GAR_HOST:-us-docker.pkg.dev}"
export AGW_CHART="${AGW_CHART:-${AGW_REGISTRY}/enterprise-agentgateway}"
export AGW_CRDS_CHART="${AGW_CRDS_CHART:-${AGW_REGISTRY}/enterprise-agentgateway-crds}"
export METALLB_VERSION="${METALLB_VERSION:-v0.14.9}"
export GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.5.1}"

export MOCK_IDP_IMAGE="mock-idp:dev"
export ECHO_UPSTREAM_IMAGE="echo-upstream:dev"

# Distinct demo "static keys" per team — what each backend injects upstream.
# Real deployments put real provider keys here (kept in a Secret, never inline).
export SALES_KEY="${SALES_KEY:-SALES-STATIC-KEY-aaaa1111}"
export ENGINEERING_KEY="${ENGINEERING_KEY:-ENG-STATIC-KEY-bbbb2222}"

load_secrets() {
  if [[ -n "${SECRETS_FILE:-}" ]]; then
    [[ -f "$SECRETS_FILE" ]] || die "SECRETS_FILE='$SECRETS_FILE' does not exist"
    set -a; source "$SECRETS_FILE"; set +a
  fi
}

require_secrets() {
  load_secrets
  if [[ -z "${AGENTGATEWAY_LICENSE_KEY:-}" ]]; then
    cat >&2 <<EOF

ERROR: missing AGENTGATEWAY_LICENSE_KEY (Enterprise AGW — jwtAuthentication +
transformation are Enterprise fields).

  export AGENTGATEWAY_LICENSE_KEY=...    # then ./scripts/quick.sh up
  or  SECRETS_FILE=/path/to/secrets.sh ./scripts/quick.sh up
EOF
    exit 1
  fi
}

kc() { kubectl --context "$CTX" "$@"; }

wait_deploy() {
  local ns="$1" name="$2" timeout="${3:-300s}"
  local end=$(( $(date +%s) + 120 ))
  until kc -n "$ns" get deployment "$name" >/dev/null 2>&1; do
    [[ $(date +%s) -ge $end ]] && { warn "deployment $ns/$name not created within 2m"; return 1; }
    sleep 3
  done
  kc -n "$ns" wait --for=condition=Available deployment/"$name" --timeout="$timeout" >/dev/null
}

check_docker() { docker info >/dev/null 2>&1 || die "docker daemon not reachable — start Docker Desktop / OrbStack"; }

ensure_gar_auth() {
  local host="$1"
  command -v gcloud >/dev/null 2>&1 || die "gcloud not installed (needed for the Enterprise AGW chart on $host). brew install --cask google-cloud-sdk"
  if ! gcloud auth print-access-token >/dev/null 2>&1; then
    [[ -t 0 ]] || die "gcloud not authenticated and no TTY. Run: gcloud auth login"
    gcloud auth login || die "gcloud auth login failed"
  fi
  grep -q "\"${host}\":" "$HOME/.docker/config.json" 2>/dev/null || gcloud auth configure-docker --quiet "$host" >/dev/null
  gcloud auth print-access-token | helm registry login -u oauth2accesstoken --password-stdin "$host" >/dev/null \
    || die "helm registry login failed for $host (macOS Keychain: click Always Allow and re-run)"
}

helm_install_with_progress() {
  local release="$1" chart="$2" namespace="$3"; shift 3
  helm --kube-context "$CTX" upgrade --install "$release" "$chart" \
    --namespace "$namespace" --create-namespace "$@" >/dev/null &
  local pid=$! start; start=$(date +%s)
  while kill -0 "$pid" 2>/dev/null; do
    sleep 15; kill -0 "$pid" 2>/dev/null || break
    local el=$(( $(date +%s) - start ))
    local pods; pods=$(kc -n "$namespace" get pods --no-headers 2>/dev/null | awk '{printf "%s[%s] ", $1, $2}')
    log "[+${el}s] ${pods:-pulling images...}"
  done
  wait "$pid"
}

build_and_load() {
  local context="$1" image="$2"
  log "docker build → $image"; docker build --quiet -t "$image" "$context" >/dev/null; ok "built $image"
  log "kind load → $image"; kind load docker-image --name "$CLUSTER_NAME" "$image" >/dev/null; ok "loaded $image"
}
