#!/usr/bin/env bash
# lib.sh — shared helpers for the agentgateway-claude-code-openai-kind lab.
# Single kind cluster running Solo Enterprise for agentgateway. The gateway
# serves the Anthropic Messages API (/v1/messages), translates each request to
# an OpenAI chat-completions call, and translates the OpenAI reply back into
# Anthropic format. JWT auth + CEL authorization sit in front; the OpenAI key
# lives only in a cluster Secret, never on the client.

set -Eeuo pipefail

# ── logging ───────────────────────────────────────────────────────────────────
__has_color() { [[ -t 2 ]] && command -v tput >/dev/null 2>&1; }
if __has_color; then
  __dim()  { tput dim;  printf '%s' "$*"; tput sgr0; }
  __ok()   { tput setaf 2; printf '✓ '; tput sgr0; printf '%s' "$*"; }
  __warn() { tput setaf 3; printf '! '; tput sgr0; printf '%s' "$*"; }
  __err()  { tput setaf 1; printf 'ERROR: '; tput sgr0; printf '%s' "$*"; }
  __step() { tput bold; printf '%s' "$*"; tput sgr0; }
else
  __dim()  { printf '%s' "$*"; }
  __ok()   { printf '✓ %s' "$*"; }
  __warn() { printf '! %s' "$*"; }
  __err()  { printf 'ERROR: %s' "$*"; }
  __step() { printf '%s' "$*"; }
fi
log()  { { __dim "  $*"; printf '\n'; } >&2; }
ok()   { { __ok "$*";    printf '\n'; } >&2; }
warn() { { __warn "$*";  printf '\n'; } >&2; }
die()  { { __err "$*";   printf '\n'; } >&2; exit 1; }
step() { printf '\n' >&2; { __step "══> $*"; printf '\n'; } >&2; }

require() { command -v "$1" >/dev/null 2>&1 || die "$1 not found — install it first"; }

# ── cluster ─────────────────────────────────────────────────────────────────
export CLUSTER="${CLUSTER:-claude-code-agw}"
export CTX="kind-${CLUSTER}"

export GW_NS="${GW_NS:-agentgateway-system}"
export GW_NAME="${GW_NAME:-agentgateway-proxy}"
export PORT="${PORT:-8080}"

# ── enterprise agentgateway chart ─────────────────────────────────────────────
# Public OCI registry. agentgateway chart versions carry a 'v' prefix.
export AGW_VERSION="${AGW_VERSION:-v2.3.4}"
export GAR_HOST="${GAR_HOST:-us-docker.pkg.dev}"
export AGW_REGISTRY="${AGW_REGISTRY:-oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts}"
export AGW_CHART="${AGW_CHART:-${AGW_REGISTRY}/enterprise-agentgateway}"
export AGW_CRDS_CHART="${AGW_CRDS_CHART:-${AGW_REGISTRY}/enterprise-agentgateway-crds}"
export GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.5.1}"

# ── JWT issuer ────────────────────────────────────────────────────────────────
export JWT_ISSUER="${JWT_ISSUER:-claude-code-lab}"
export JWT_AUDIENCE="${JWT_AUDIENCE:-anthropic-api}"
export JWT_KID="${JWT_KID:-claude-code-key}"

# ── secrets ───────────────────────────────────────────────────────────────────
# Two values:
#   AGENTGATEWAY_LICENSE_KEY  — Solo Enterprise agentgateway license
#   OPENAI_API_KEY            — the backend model credential (held in-cluster)
# OPENAI_API_KEY may also be read from a file via OPENAI_KEY_FILE (default below).
export OPENAI_KEY_FILE="${OPENAI_KEY_FILE:-$HOME/code/solo/secrets/openai.key}"

load_secrets() {
  if [[ -n "${SECRETS_FILE:-}" ]]; then
    [[ -f "$SECRETS_FILE" ]] || die "SECRETS_FILE='$SECRETS_FILE' does not exist"
    set -a; source "$SECRETS_FILE"; set +a
  fi
  if [[ -z "${OPENAI_API_KEY:-}" && -f "$OPENAI_KEY_FILE" ]]; then
    OPENAI_API_KEY="$(tr -d ' \t\r\n' < "$OPENAI_KEY_FILE")"
    export OPENAI_API_KEY
  fi
}

require_license() {
  load_secrets
  if [[ -z "${AGENTGATEWAY_LICENSE_KEY:-}" ]]; then
    cat >&2 <<EOF

ERROR: no Solo Enterprise agentgateway license key found (AGENTGATEWAY_LICENSE_KEY).
  export AGENTGATEWAY_LICENSE_KEY=...   (or: SECRETS_FILE=/path/to/secrets.sh)
  License: ask your Solo account team.
EOF
    exit 1
  fi
}

require_openai() {
  load_secrets
  if [[ -z "${OPENAI_API_KEY:-}" ]]; then
    cat >&2 <<EOF

ERROR: no OpenAI API key found.
  export OPENAI_API_KEY=sk-...
  or drop it in a file:  echo sk-... > $OPENAI_KEY_FILE
EOF
    exit 1
  fi
}

# ── kubectl helpers ───────────────────────────────────────────────────────────
kctx() { kubectl --context "$CTX" "$@"; }

check_docker() {
  docker info >/dev/null 2>&1 || die "docker daemon not reachable — start Docker Desktop / OrbStack"
}

wait_deploy() {
  local ns="$1" name="$2" timeout="${3:-300s}"
  local end=$(( $(date +%s) + 180 ))
  until kctx -n "$ns" get deployment "$name" >/dev/null 2>&1; do
    [[ $(date +%s) -ge $end ]] && { warn "deployment $ns/$name not created within 3m"; return 1; }
    sleep 3
  done
  kctx -n "$ns" wait --for=condition=Available "deployment/$name" --timeout="$timeout" >/dev/null
}

ensure_gar_auth() {
  local host="$1"
  command -v gcloud >/dev/null 2>&1 || die "gcloud not installed — brew install --cask google-cloud-sdk, then gcloud auth login"
  if ! gcloud auth print-access-token >/dev/null 2>&1; then
    [[ -t 0 ]] || die "gcloud not authenticated and no TTY. Run: gcloud auth login"
    log "chart registry $host requires gcloud auth — running 'gcloud auth login'"
    gcloud auth login || die "gcloud auth login failed"
  fi
  if ! grep -q "\"${host}\":" "$HOME/.docker/config.json" 2>/dev/null; then
    log "configuring docker credential helper for $host"
    gcloud auth configure-docker --quiet "$host" >/dev/null
  fi
  log "helm registry login → $host"
  gcloud auth print-access-token \
    | helm registry login -u oauth2accesstoken --password-stdin "$host" >/dev/null \
    || die "helm registry login failed for $host (if a Keychain dialog appeared, click Always Allow and re-run)"
}

helm_install_with_progress() {
  local release="$1" chart="$2" namespace="$3"
  shift 3
  helm --kube-context "$CTX" upgrade --install "$release" "$chart" \
    --namespace "$namespace" --create-namespace "$@" >/dev/null &
  local helm_pid=$! start; start=$(date +%s)
  while kill -0 "$helm_pid" 2>/dev/null; do
    sleep 15
    kill -0 "$helm_pid" 2>/dev/null || break
    local elapsed=$(( $(date +%s) - start ))
    local pods; pods=$(kctx -n "$namespace" get pods --no-headers 2>/dev/null \
      | awk '{printf "%s[%s] ", $1, $2}')
    [[ -n "$pods" ]] && log "[+${elapsed}s] pods: ${pods}" || log "[+${elapsed}s] pulling images..."
  done
  wait "$helm_pid"
}
