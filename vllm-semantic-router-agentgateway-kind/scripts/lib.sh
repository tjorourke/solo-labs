#!/usr/bin/env bash
# lib.sh — shared helpers for vllm-semantic-router-agentgateway-kind.
#
# This lab runs the OSS upstream agentgateway (the Linux Foundation project,
# cr.agentgateway.dev). That distribution is required here: the vLLM Semantic
# Router works by buffering the request body over ExtProc and rewriting it, and
# only the upstream agentgateway exposes the ExtProc body-mode controls
# (processingOptions.allowModeOverride) that the router negotiates. Solo's
# agentgateway CRDs (OSS-packaged and Enterprise) do not expose those knobs, so
# the router classifies but the rewritten body is dropped. See README.md.
#
# No license key and no registry auth: the OSS charts pull anonymously.

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
export CLUSTER_NAME="${CLUSTER_NAME:-vllm-sr}"
export CTX="kind-${CLUSTER_NAME}"

# OSS upstream agentgateway (cr.agentgateway.dev). v1.3.0-alpha.1+ is required
# for ExtProc processingOptions + allowModeOverride. GatewayClass is
# `agentgateway`.
export AGW_VERSION="${AGW_VERSION:-$AGW_OSS_VERSION}"
export AGW_CRDS_CHART="${AGW_CRDS_CHART:-oci://cr.agentgateway.dev/charts/agentgateway-crds}"
export AGW_CHART="${AGW_CHART:-oci://cr.agentgateway.dev/charts/agentgateway}"

# Gateway API CRDs. The article installs v1.5.0; ExtProc rides on the
# experimental features flag set on the controller (see 02-agentgateway.sh).
export GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.5.0}"

# Upstream vLLM Semantic Router Helm chart (a gRPC ExtProc service). The
# agentgateway preset values are vendored at yaml/semantic-router/values.yaml.
export SEMANTIC_ROUTER_CHART="${SEMANTIC_ROUTER_CHART:-oci://ghcr.io/vllm-project/charts/semantic-router}"
export SEMANTIC_ROUTER_VERSION="${SEMANTIC_ROUTER_VERSION:-v0.0.0-latest}"

# vLLM simulator image (base model + 6 mock LoRA adapters, no weights).
export VLLM_SIM_IMAGE="${VLLM_SIM_IMAGE:-ghcr.io/llm-d/llm-d-inference-sim:v0.5.0}"

# ── secrets loader ────────────────────────────────────────────────────────────
# Nothing is required (OSS charts need no license/auth). HF_TOKEN is optional
# and only speeds up the router's first-start model download. Export it directly
# or point SECRETS_FILE at a sourceable shell file.
load_secrets() {
  if [[ -n "${SECRETS_FILE:-}" ]]; then
    [[ -f "$SECRETS_FILE" ]] || die "SECRETS_FILE='$SECRETS_FILE' does not exist"
    set -a; source "$SECRETS_FILE"; set +a
  fi
}

# Kept for call-site compatibility; OSS needs no required secrets.
require_secrets() { load_secrets; }

# ── kubectl helpers ───────────────────────────────────────────────────────────
kc() { kubectl --context "$CTX" "$@"; }

# Poll for a deployment to exist (a controller may create it asynchronously) and
# then wait for it to become Available.
wait_deploy() {
  local ns="$1" name="$2" timeout="${3:-300s}"
  local end=$(( $(date +%s) + 180 ))
  until kc -n "$ns" get deployment "$name" >/dev/null 2>&1; do
    [[ $(date +%s) -ge $end ]] && {
      warn "deployment $ns/$name not created within 3m"
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

# helm_install_with_progress — like `helm upgrade --install --wait` but prints
# periodic pod-status snapshots while it blocks. The bare --wait flag is silent
# for minutes on cold clusters (image pulls can take 2-5 min), which feels like
# a hang. Use this instead.
#
# Usage: helm_install_with_progress <release> <chart> <namespace> [extra args...]
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
