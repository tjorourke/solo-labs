#!/usr/bin/env bash
# lib.sh — shared helpers for agentic-external-guardrail-kind scripts.
#
# Sibling of ../agentic-pii-guardrail-kind/scripts/lib.sh — the cluster + AGW
# install path is intentionally identical so Part 1 and Part 2 feel the same.
# Part 2 swaps the local guardrail webhook for an adapter that forwards to an
# EXTERNAL guardrail service (NeuralTrust GAF, or the bundled stub).

set -Eeuo pipefail

# Central product/infra versions (generated from versions.json).
__versions_env="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/versions.env"
[ -f "$__versions_env" ] && . "$__versions_env"
: "${AGW_ENT_VERSION:=v2.3.4}"; : "${AGW_OSS_VERSION:=v1.3.0-alpha.1}"; : "${AGW_CALVER_VERSION:=v2026.5.2}"

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
log()    { { __dim "  $*"; printf '\n'; } >&2; }
ok()     { { __ok "$*";    printf '\n'; } >&2; }
warn()   { { __warn "$*";  printf '\n'; } >&2; }
die()    { { __err "$*";   printf '\n'; } >&2; exit 1; }
step()   { printf '\n' >&2; { __step "══> $*"; printf '\n'; } >&2; }

require() { command -v "$1" >/dev/null 2>&1 || die "$1 not found — install it first"; }

# ── cluster constants ─────────────────────────────────────────────────────────
export CLUSTER_NAME="${CLUSTER_NAME:-extguard}"
export CTX="kind-${CLUSTER_NAME}"

# Enterprise agentgateway — needed for promptGuard (the webhook backendRef).
export AGW_VERSION="${AGW_VERSION:-$AGW_ENT_VERSION}"
export AGW_REGISTRY="${AGW_REGISTRY:-oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts}"
export AGW_GAR_HOST="${AGW_GAR_HOST:-us-docker.pkg.dev}"
export AGW_CHART="${AGW_CHART:-${AGW_REGISTRY}/enterprise-agentgateway}"
export AGW_CRDS_CHART="${AGW_CRDS_CHART:-${AGW_REGISTRY}/enterprise-agentgateway-crds}"

export METALLB_VERSION="${METALLB_VERSION:-v0.14.9}"
export GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.4.0}"

# Image tags for the two custom services we build + kind-load.
export GUARD_ADAPTER_IMAGE="guard-adapter:dev"
export TRUSTGUARD_STUB_IMAGE="trustguard-stub:dev"

# External guardrail wiring. Stub by default; set these to flip to real mode.
#   GUARD_URL      — the external guardrail evaluate endpoint
#   GUARD_API_KEY  — bearer token for the external guardrail (empty for stub)
#   GUARD_MODE     — label shown in /events ("stub" | "neuraltrust")
export GUARD_URL="${GUARD_URL:-http://trustguard-stub.extguard-demo.svc:8080/v1/guard}"
export GUARD_API_KEY="${GUARD_API_KEY:-}"
export GUARD_MODE="${GUARD_MODE:-stub}"
# NeuralTrust GAF only: the policy_id the actions API is keyed to (from the console).
export GUARD_POLICY_ID="${GUARD_POLICY_ID:-}"

# ── secrets loader ────────────────────────────────────────────────────────────
#   ANTHROPIC_API_KEY        — the Anthropic backend (the actual LLM call)
#   AGENTGATEWAY_LICENSE_KEY — Solo Enterprise AGW license (promptGuard is enterprise)
load_secrets() {
  if [[ -n "${SECRETS_FILE:-}" ]]; then
    [[ -f "$SECRETS_FILE" ]] || die "SECRETS_FILE='$SECRETS_FILE' does not exist"
    set -a; source "$SECRETS_FILE"; set +a
  fi
}

require_secrets() {
  load_secrets
  local missing=()
  [[ -z "${ANTHROPIC_API_KEY:-}" ]]        && missing+=("ANTHROPIC_API_KEY")
  [[ -z "${AGENTGATEWAY_LICENSE_KEY:-}" ]] && missing+=("AGENTGATEWAY_LICENSE_KEY")
  if (( ${#missing[@]} > 0 )); then
    cat >&2 <<EOF

ERROR: missing required env vars: ${missing[*]}

Two ways to provide them:
  1. export in your current shell:
       export ANTHROPIC_API_KEY=sk-ant-...
       export AGENTGATEWAY_LICENSE_KEY=...
       ./scripts/quick.sh up

  2. point at a sourceable file:
       SECRETS_FILE=/path/to/secrets.sh ./scripts/quick.sh up

  Anthropic key:   https://console.anthropic.com/
  AGW license:     ask your Solo account team
EOF
    exit 1
  fi
}

# ── kubectl helpers ───────────────────────────────────────────────────────────
kc() { kubectl --context "$CTX" "$@"; }

wait_deploy() {
  local ns="$1" name="$2" timeout="${3:-300s}"
  local end=$(( $(date +%s) + 120 ))
  until kc -n "$ns" get deployment "$name" >/dev/null 2>&1; do
    [[ $(date +%s) -ge $end ]] && {
      warn "deployment $ns/$name not created within 2m"
      return 1
    }
    sleep 3
  done
  kc -n "$ns" wait --for=condition=Available deployment/"$name" --timeout="$timeout" >/dev/null
}

check_docker() {
  if ! docker info >/dev/null 2>&1; then
    die "docker daemon not reachable — start Docker Desktop / OrbStack"
  fi
}

# ensure_gar_auth — idempotent gcloud + docker + helm OCI auth for Google
# Artifact Registry. The Solo Enterprise AGW chart is public but helm OCI pull
# still returns 401 without `helm registry login` using a gcloud access token.
ensure_gar_auth() {
  local host="$1"
  if ! command -v gcloud >/dev/null 2>&1; then
    cat >&2 <<EOF

ERROR: Solo Enterprise AGW chart lives at $host (Google Artifact Registry),
but gcloud isn't installed.

  Install on macOS:  brew install --cask google-cloud-sdk
  Then:              gcloud auth login
                     gcloud auth configure-docker $host

  After that, re-run ./scripts/quick.sh up.
EOF
    exit 1
  fi
  if ! gcloud auth print-access-token >/dev/null 2>&1; then
    if [[ ! -t 0 ]]; then
      die "gcloud not authenticated and no TTY for prompt. Run: gcloud auth login (then re-run)"
    fi
    echo "" >&2
    echo "  Chart registry $host requires gcloud auth — running 'gcloud auth login' now." >&2
    gcloud auth login || die "gcloud auth login failed"
  fi
  if ! grep -q "\"${host}\":" "$HOME/.docker/config.json" 2>/dev/null; then
    log "configuring docker credential helper for $host"
    gcloud auth configure-docker --quiet "$host" >/dev/null
  fi
  log "helm registry login → $host"
  if ! gcloud auth print-access-token \
       | helm registry login -u oauth2accesstoken --password-stdin "$host" >/dev/null; then
    cat >&2 <<EOF

ERROR: helm registry login failed for $host.

  If a macOS Keychain dialog popped up, click "Always Allow" and re-run.
  Verify manually:
    gcloud auth print-access-token \\
      | helm registry login -u oauth2accesstoken --password-stdin $host

EOF
    exit 1
  fi
}

# helm_install_with_progress — `helm upgrade --install --wait` with periodic
# pod-status snapshots, because bare --wait is silent for minutes on cold pulls.
helm_install_with_progress() {
  local release="$1" chart="$2" namespace="$3"
  shift 3
  helm --kube-context "$CTX" upgrade --install "$release" "$chart" \
    --namespace "$namespace" --create-namespace "$@" >/dev/null &
  local helm_pid=$!
  local start
  start=$(date +%s)
  while kill -0 "$helm_pid" 2>/dev/null; do
    sleep 15
    kill -0 "$helm_pid" 2>/dev/null || break
    local elapsed=$(( $(date +%s) - start ))
    local pods_summary
    pods_summary=$(kc -n "$namespace" get pods --no-headers 2>/dev/null \
      | awk '{printf "%s[%s] ", $1, $2}')
    if [[ -n "$pods_summary" ]]; then
      log "[+${elapsed}s] pods: ${pods_summary}"
    else
      log "[+${elapsed}s] still pulling images / creating pods..."
    fi
  done
  wait "$helm_pid"
}

# Build + kind-load an image. Re-runs are no-ops for kind load.
build_and_load() {
  local context="$1" image="$2"
  log "docker build → $image"
  docker build --quiet -t "$image" "$context" >/dev/null
  ok "built $image"
  log "kind load → $image (cluster $CLUSTER_NAME)"
  kind load docker-image --name "$CLUSTER_NAME" "$image" >/dev/null
  ok "loaded $image into kind"
}
