#!/usr/bin/env bash
# lib.sh — shared helpers for the kgateway-versioned-routing-kind lab.
# Sourced by every script under ./scripts/. Mirrors the agentic-budgets-kind
# lab so the labs share muscle memory.

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
log()  { { __dim "  $*"; printf '\n'; } >&2; }
ok()   { { __ok "$*";    printf '\n'; } >&2; }
warn() { { __warn "$*";  printf '\n'; } >&2; }
die()  { { __err "$*";   printf '\n'; } >&2; exit 1; }
step() { printf '\n' >&2; { __step "══> $*"; printf '\n'; } >&2; }

require() { command -v "$1" >/dev/null 2>&1 || die "$1 not found — install it first"; }

# ── clusters ──────────────────────────────────────────────────────────────────
# Three kind clusters: one edge gateway + two versioned app clusters.
export EDGE_CLUSTER="${EDGE_CLUSTER:-kgw-edge}"
export APP_LATEST_CLUSTER="${APP_LATEST_CLUSTER:-app-latest}"
export APP_V2_CLUSTER="${APP_V2_CLUSTER:-app-v2}"

export EDGE_CTX="kind-${EDGE_CLUSTER}"
export APP_LATEST_CTX="kind-${APP_LATEST_CLUSTER}"
export APP_V2_CTX="kind-${APP_V2_CLUSTER}"

export GW_NS="${GW_NS:-kgateway-system}"
export APP_NODEPORT="${APP_NODEPORT:-30080}"

# ── kgateway enterprise chart ─────────────────────────────────────────────────
# Public OCI registry (Google Artifact Registry). Verified live: the
# enterprise-kgateway + enterprise-kgateway-crds charts both publish 2.2.0.
export KGW_VERSION="${KGW_VERSION:-2.2.0}"
export GAR_HOST="${GAR_HOST:-us-docker.pkg.dev}"
export KGW_REGISTRY="${KGW_REGISTRY:-oci://us-docker.pkg.dev/solo-public/enterprise-kgateway/charts}"
export KGW_CHART="${KGW_CHART:-${KGW_REGISTRY}/enterprise-kgateway}"
export KGW_CRDS_CHART="${KGW_CRDS_CHART:-${KGW_REGISTRY}/enterprise-kgateway-crds}"

# Kubernetes Gateway API. kgateway 2.2 requires 1.5.x. Standard channel is
# enough — this lab only uses HTTPRoute.
export GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.5.1}"

# ── secrets ───────────────────────────────────────────────────────────────────
# One required value: a Solo Enterprise for kgateway license key, passed to the
# chart as licensing.licenseKey. We accept KGATEWAY_LICENSE_KEY and fall back to
# the GLOO_GATEWAY_LICENSE_KEY / SOLO_LICENSE_KEY names that already live in the
# shared secrets file.
load_secrets() {
  if [[ -n "${SECRETS_FILE:-}" ]]; then
    [[ -f "$SECRETS_FILE" ]] || die "SECRETS_FILE='$SECRETS_FILE' does not exist"
    set -a; source "$SECRETS_FILE"; set +a
  fi
  export KGATEWAY_LICENSE_KEY="${KGATEWAY_LICENSE_KEY:-${GLOO_GATEWAY_LICENSE_KEY:-${SOLO_LICENSE_KEY:-}}}"
}

require_license() {
  load_secrets
  if [[ -z "${KGATEWAY_LICENSE_KEY:-}" ]]; then
    cat >&2 <<EOF

ERROR: no Solo Enterprise for kgateway license key found.

Provide one of KGATEWAY_LICENSE_KEY / GLOO_GATEWAY_LICENSE_KEY / SOLO_LICENSE_KEY:
  1. export in your shell:
       export KGATEWAY_LICENSE_KEY=...
       ./scripts/quick.sh up
  2. point at a sourceable file:
       SECRETS_FILE=/path/to/secrets.sh ./scripts/quick.sh up

  License: ask your Solo account team.
EOF
    exit 1
  fi
}

# ── kubectl helpers ───────────────────────────────────────────────────────────
# kctx <context> <args...> — run kubectl against a named context.
kctx() { local ctx="$1"; shift; kubectl --context "$ctx" "$@"; }

check_docker() {
  docker info >/dev/null 2>&1 || die "docker daemon not reachable — start Docker Desktop / OrbStack"
}

# kind_node_ip <cluster> — the docker-network IP of a single-node kind cluster's
# control-plane node, reachable from pods in the other kind clusters.
kind_node_ip() {
  local cluster="$1"
  docker inspect -f '{{range .NetworkSettings.Networks}}{{if .IPAddress}}{{.IPAddress}}{{end}}{{end}}' \
    "${cluster}-control-plane" 2>/dev/null | head -1
}

# wait_deploy <ctx> <ns> <name> [timeout] — poll for a deployment to exist, then
# for it to become Available.
wait_deploy() {
  local ctx="$1" ns="$2" name="$3" timeout="${4:-300s}"
  local end=$(( $(date +%s) + 180 ))
  until kctx "$ctx" -n "$ns" get deployment "$name" >/dev/null 2>&1; do
    [[ $(date +%s) -ge $end ]] && { warn "deployment $ns/$name not created within 3m"; return 1; }
    sleep 3
  done
  kctx "$ctx" -n "$ns" wait --for=condition=Available "deployment/$name" --timeout="$timeout" >/dev/null
}

# ensure_gar_auth <host> — idempotent gcloud + docker + helm OCI auth for a
# Google Artifact Registry host. solo-public/* is public, but helm OCI pull
# still 401s without a registry login using a gcloud access token.
ensure_gar_auth() {
  local host="$1"
  if ! command -v gcloud >/dev/null 2>&1; then
    cat >&2 <<EOF

ERROR: the enterprise-kgateway chart lives at $host (Google Artifact Registry),
but gcloud isn't installed.
  Install on macOS:  brew install --cask google-cloud-sdk
  Then:              gcloud auth login
EOF
    exit 1
  fi
  if ! gcloud auth print-access-token >/dev/null 2>&1; then
    [[ -t 0 ]] || die "gcloud not authenticated and no TTY for prompt. Run: gcloud auth login"
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

# helm_install_with_progress <ctx> <release> <chart> <ns> [extra args...] — like
# `helm upgrade --install --wait` but prints periodic pod snapshots while it
# blocks (cold image pulls are silent for minutes otherwise).
helm_install_with_progress() {
  local ctx="$1" release="$2" chart="$3" namespace="$4"
  shift 4
  helm --kube-context "$ctx" upgrade --install "$release" "$chart" \
    --namespace "$namespace" --create-namespace "$@" >/dev/null &
  local helm_pid=$! start; start=$(date +%s)
  while kill -0 "$helm_pid" 2>/dev/null; do
    sleep 15
    kill -0 "$helm_pid" 2>/dev/null || break
    local elapsed=$(( $(date +%s) - start ))
    local pods; pods=$(kctx "$ctx" -n "$namespace" get pods --no-headers 2>/dev/null \
      | awk '{printf "%s[%s] ", $1, $2}')
    [[ -n "$pods" ]] && log "[+${elapsed}s] pods: ${pods}" || log "[+${elapsed}s] pulling images..."
  done
  wait "$helm_pid"
}
