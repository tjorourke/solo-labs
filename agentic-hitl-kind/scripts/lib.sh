#!/usr/bin/env bash
# lib.sh — shared helpers for agentic-hitl-kind scripts.
#
# Sourced by every script under ./scripts/. Follows the inline-helpers
# convention used by agentgw-multi-cluster-kind (each lab carries its own
# log/step/die so scripts are runnable standalone).

set -Eeuo pipefail

# Central product/infra versions (generated from versions.json). Sourcing
# this lets a version bump in one place flow to every lab; runtime env wins.
__versions_env="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/versions.env"
[ -f "$__versions_env" ] && . "$__versions_env"

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
export CLUSTER_NAME="${CLUSTER_NAME:-hitl}"
export CTX="kind-${CLUSTER_NAME}"
export AGW_VERSION="${AGW_VERSION:-v1.2.1}"
export AGW_CHART="${AGW_CHART:-oci://cr.agentgateway.dev/charts/agentgateway}"
export AGW_CRDS_CHART="${AGW_CRDS_CHART:-oci://cr.agentgateway.dev/charts/agentgateway-crds}"
export KAGENT_VERSION="${KAGENT_VERSION:-}"   # empty = chart default
export METALLB_VERSION="${METALLB_VERSION:-v0.14.9}"
export GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.4.0}"

# Image tags for the three custom services we build + kind-load
export OPS_TOOLS_IMAGE="ops-tools:dev"
export HITL_EXTAUTH_IMAGE="hitl-extauth:dev"
export HITL_UI_IMAGE="hitl-ui:dev"
export LANGGRAPH_AGENT_IMAGE="langgraph-agent:dev"

# ── secrets loader ────────────────────────────────────────────────────────────
# OSS agentgateway needs no license. The only required secret is the model key:
#   1. export ANTHROPIC_API_KEY=...
#   2. SECRETS_FILE=/path/to/secrets.sh  (sourceable shell)
load_secrets() {
  if [[ -n "${SECRETS_FILE:-}" ]]; then
    [[ -f "$SECRETS_FILE" ]] || die "SECRETS_FILE='$SECRETS_FILE' does not exist"
    set -a; source "$SECRETS_FILE"; set +a
  fi
}

require_secrets() {
  load_secrets
  if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
    cat >&2 <<EOF

ERROR: ANTHROPIC_API_KEY not set.

Two ways to provide it:
  1. export in your current shell:
       export ANTHROPIC_API_KEY=sk-ant-...
       ./scripts/quick.sh up

  2. point at a sourceable file:
       SECRETS_FILE=/path/to/secrets.sh ./scripts/quick.sh up

Get an Anthropic API key at https://console.anthropic.com/.
EOF
    exit 1
  fi
}

# ── kubectl helpers ───────────────────────────────────────────────────────────
kc() { kubectl --context "$CTX" "$@"; }

# Poll for a deployment to exist (operator may create it asynchronously) and
# then for it to become Available.
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

# Pre-flight checks shared by all phase scripts.
check_docker() {
  if ! docker info >/dev/null 2>&1; then
    die "docker daemon not reachable — start Docker Desktop / OrbStack"
  fi
}


# helm_install_with_progress — like `helm upgrade --install --wait` but
# prints periodic pod-status snapshots while it blocks. The bare --wait flag
# is silent for minutes on cold clusters (image pulls from ghcr.io / GAR
# can take 2-5 min), which feels like a hang. Use this instead.
#
# Usage: helm_install_with_progress <release> <chart> <namespace> [extra helm args...]
#
# Runs helm in the background, polls `kubectl -n <ns> get pods` every 15s,
# prints a one-line summary of pod names + Ready state, and exits with helm's
# exit code. Sends pod output to stderr so it interleaves with step()/log().
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

# Build + kind-load an image. Skips the load if the image is already present
# on the kind nodes.
build_and_load() {
  local context="$1" image="$2"
  log "docker build → $image"
  docker build --quiet -t "$image" "$context" >/dev/null
  ok "built $image"

  log "kind load → $image (cluster $CLUSTER_NAME)"
  kind load docker-image --name "$CLUSTER_NAME" "$image" >/dev/null
  ok "loaded $image into kind"
}
