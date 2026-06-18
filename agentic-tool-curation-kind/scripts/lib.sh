#!/usr/bin/env bash
# lib.sh — shared helpers for agentic-tool-curation-kind scripts.
#
# Sourced by every script under ./scripts/. Mirrors the agentic-mcp-rbac-kind
# layout — this lab is a sibling that swaps the "RBAC at the gateway" story
# for "agentregistry is the source of truth for which tools are approved".

set -Eeuo pipefail

# Central product/infra versions (generated from versions.json). Sourcing this
# lets a version bump in one place flow to every lab; runtime env still wins.
# Mirrored into solo-labs too (sync-to-labs.sh). The := fallbacks keep a lab
# runnable even if versions.env is absent (e.g. a dir copied out standalone).
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
export CLUSTER_NAME="${CLUSTER_NAME:-curation}"
export CTX="kind-${CLUSTER_NAME}"

# Enterprise agentgateway chart + version. Unlike the hitl lab (which uses the
# OSS chart at cr.agentgateway.dev), this lab needs the enterprise data plane
# because MCP authorization with CEL on jwt.* + mcp.tool.name lives in the
# enterprise control plane (EnterpriseAgentgatewayPolicy).
#
# TODO(unverified): The exact OCI path below has not been pulled by Claude
# during build. The Solo Enterprise agentgateway chart usually lives at
# `oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway-helm/...`,
# but registry paths sometimes change. On first 'quick.sh up', if the helm
# Public OCI registry (no auth needed). Path + version match
# `agentic-pii-guardrail-kind/scripts/lib.sh` which is end-to-end verified.
export AGW_VERSION="${AGW_VERSION:-$AGW_ENT_VERSION}"
export AGW_REGISTRY="${AGW_REGISTRY:-oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts}"
export AGW_GAR_HOST="${AGW_GAR_HOST:-us-docker.pkg.dev}"
export AGW_CHART="${AGW_CHART:-${AGW_REGISTRY}/enterprise-agentgateway}"
export AGW_CRDS_CHART="${AGW_CRDS_CHART:-${AGW_REGISTRY}/enterprise-agentgateway-crds}"

export KAGENT_VERSION="${KAGENT_VERSION:-}"   # empty = chart default
export METALLB_VERSION="${METALLB_VERSION:-v0.14.9}"
export GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.4.0}"

# Solo Enterprise for agentregistry chart. The enterprise chart isn't
# public-OCI-pullable from kind without an authenticated dance similar to
# AGW's — and the registry itself wants Postgres + pgvector + a license.
# This lab uses the OSS chart by default for reliability; flip AR_USE_ENT=1
# (and supply AR_ENT_LICENSE_KEY) to try the enterprise chart instead.
#
# OSS chart: oci://ghcr.io/agentregistry-dev/agentregistry/charts/agentregistry
# Enterprise: oci://us-docker.pkg.dev/solo-public/agentregistry-enterprise/...
#
# Either one provides the v0/apply REST API + Postgres-backed catalogue we
# need; the lab calls /v0/* the same way against both. The "is this real
# enterprise?" story isn't load-bearing for the demo — what matters is that
# the registry's curated MCPServer artifact is what the policy-sync controller
# reads to drive every gateway enforcement rule.
export AR_OSS_VERSION="${AR_OSS_VERSION:-v0.3.2}"
export AR_OSS_CHART="${AR_OSS_CHART:-oci://ghcr.io/agentregistry-dev/agentregistry/charts/agentregistry}"
export AR_ENT_VERSION="${AR_ENT_VERSION:-v0.0.10}"
export AR_ENT_CHART="${AR_ENT_CHART:-oci://us-docker.pkg.dev/solo-public/agentregistry-enterprise/charts/agentregistry-enterprise}"
export AR_USE_ENT="${AR_USE_ENT:-0}"

# Image tags for the custom services we build + kind-load.
export ROGUE_MCP_IMAGE="rogue-mcp:dev"
export DESCRIPTION_SHIM_IMAGE="description-shim:dev"
export POLICY_SYNC_IMAGE="policy-sync:dev"
export TOOL_POLICY_EXTAUTH_IMAGE="tool-policy-extauth:dev"
export JWT_ISSUER_IMAGE="jwt-issuer:dev"
export CURATION_INSPECTOR_UI_IMAGE="curation-inspector-ui:dev"

# ── secrets loader ────────────────────────────────────────────────────────────
# One required env var:
#   AGENTGATEWAY_LICENSE_KEY — Solo Enterprise AGW license; the data plane
#                              refuses to start without it.
# This lab does NOT need an Anthropic key — the inspector UI is a pure
# tools/list + tools/call driver, not a Claude ReAct loop.
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

ERROR: missing required env var: AGENTGATEWAY_LICENSE_KEY

Two ways to provide it:
  1. export in your current shell:
       export AGENTGATEWAY_LICENSE_KEY=...
       ./scripts/quick.sh up

  2. point at a sourceable file:
       SECRETS_FILE=/path/to/secrets.sh ./scripts/quick.sh up

  Ask your Solo account team for the AGW license key.
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

# Poll for a secret to exist — used after jwt-issuer comes up; it writes
# three Secrets (jwt-alice, jwt-bob, jwt-carol) from inside the pod.
wait_secret() {
  local ns="$1" name="$2" timeout="${3:-120}"
  local end=$(( $(date +%s) + timeout ))
  until kc -n "$ns" get secret "$name" >/dev/null 2>&1; do
    [[ $(date +%s) -ge $end ]] && {
      warn "secret $ns/$name not created within ${timeout}s"
      return 1
    }
    sleep 2
  done
}

# Pre-flight checks shared by all phase scripts.
check_docker() {
  if ! docker info >/dev/null 2>&1; then
    die "docker daemon not reachable — start Docker Desktop / OrbStack"
  fi
}

# ensure_gar_auth — idempotent gcloud + docker + helm OCI auth for a Google
# Artifact Registry host (e.g. us-docker.pkg.dev). Even though solo-public/* is
# public, helm OCI pull returns 401 without `helm registry login` using a
# gcloud access token. Lifted from agentic-pii-guardrail-kind.
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
      die "gcloud not authenticated and no TTY for prompt. Run: gcloud auth login (then re-run this script)"
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
  To verify auth manually:

    gcloud auth print-access-token \\
      | helm registry login -u oauth2accesstoken --password-stdin $host

  Expected output: "Login Succeeded".
EOF
    exit 1
  fi
}

# helm_install_with_progress — like `helm upgrade --install --wait` but
# prints periodic pod-status snapshots while it blocks. The bare --wait flag
# is silent for minutes on cold clusters (image pulls from ghcr.io / GAR
# can take 2-5 min), which feels like a hang. Use this instead.
#
# Usage: helm_install_with_progress <release> <chart> <namespace> [extra helm args...]
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
