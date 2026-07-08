#!/usr/bin/env bash
# lib.sh — shared helpers for agentgateway-inference-routing-kind.
#
# One kind cluster. agentgateway fronts a self-hosted LLM pool via the Gateway
# API Inference Extension (GIE): an HTTPRoute points at an InferencePool, and
# the GIE Endpoint Picker (EPP) chooses which model-server replica serves each
# request from live vLLM metrics — KV-cache usage and queue depth. That is the
# "caching" story: route to the replica that already holds the prompt's prefix
# in its KV cache so it skips prefill, and away from a saturated one.
#
# The model servers are the llm-d inference simulator (no GPU): they serve the
# OpenAI API and expose the same Prometheus gauges (vllm:gpu_cache_usage_perc,
# vllm:num_requests_waiting) a real vLLM would, with values we pin so the EPP's
# routing decision is deterministic and demoable on a laptop.
#
# Edition: the whole flow runs on OSS agentgateway (agentgateway.dev) as well as
# Solo Enterprise (enterpriseagentgateway.solo.io). Default is Enterprise; set
# AGW_EDITION=oss to run the OSS path (yaml-oss/). Enterprise needs a license.

set -Eeuo pipefail

# Central product/infra versions (generated from versions.json). Runtime env
# still wins; the := fallbacks keep the lab runnable if versions.env is absent.
__versions_env="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/versions.env"
[ -f "$__versions_env" ] && . "$__versions_env"
: "${AGW_ENT_VERSION:=v2.3.4}"
: "${AGW_OSS_VERSION:=v1.3.1}"
: "${GATEWAY_API_VERSION:=v1.5.1}"
: "${GIE_VERSION:=v1.4.0}"
: "${VLLM_SIM_IMAGE:=ghcr.io/llm-d/llm-d-inference-sim:v0.5.0}"

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

# ── cluster + namespace constants ───────────────────────────────────────────────
export CLUSTER_NAME="${CLUSTER_NAME:-inference}"
export CTX="kind-${CLUSTER_NAME}"
export NS="${NS:-inference}"
export AGW_NS="${AGW_NS:-agentgateway-system}"

# ── edition (enterprise default, oss switch) ────────────────────────────────────
# The manifests in yaml/ are edition-neutral — they use the shared agentgateway.dev
# and GIE APIs. The only per-edition difference is the GatewayClass name (injected
# at apply time) and the Helm chart/registry. So one yaml/ dir serves both.
export AGW_EDITION="${AGW_EDITION:-enterprise}"
export YAML_DIR="yaml"
if [[ "$AGW_EDITION" == "oss" ]]; then
  export AGW_VERSION="${AGW_VERSION:-$AGW_OSS_VERSION}"
  export AGW_CRDS_CHART="${AGW_CRDS_CHART:-oci://cr.agentgateway.dev/charts/agentgateway-crds}"
  export AGW_CHART="${AGW_CHART:-oci://cr.agentgateway.dev/charts/agentgateway}"
  export GATEWAY_CLASS="${GATEWAY_CLASS:-agentgateway}"
else
  export AGW_VERSION="${AGW_VERSION:-$AGW_ENT_VERSION}"
  export AGW_CRDS_CHART="${AGW_CRDS_CHART:-oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds}"
  export AGW_CHART="${AGW_CHART:-oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway}"
  export GATEWAY_CLASS="${GATEWAY_CLASS:-enterprise-agentgateway}"
fi

# Gateway API Inference Extension: CRD bundle + the EPP/InferencePool Helm chart.
export GIE_MANIFESTS="${GIE_MANIFESTS:-https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/${GIE_VERSION}/manifests.yaml}"
export GIE_POOL_CHART="${GIE_POOL_CHART:-oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool}"

# ── secrets loader ──────────────────────────────────────────────────────────────
# Enterprise needs AGENTGATEWAY_LICENSE_KEY (from the secrets file or the env).
# OSS needs nothing. Point SECRETS_FILE at a sourceable shell file, or export
# AGENTGATEWAY_LICENSE_KEY directly.
load_secrets() {
  if [[ -n "${SECRETS_FILE:-}" ]]; then
    [[ -f "$SECRETS_FILE" ]] || die "SECRETS_FILE='$SECRETS_FILE' does not exist"
    set -a; source "$SECRETS_FILE"; set +a
  fi
}

require_secrets() {
  load_secrets
  if [[ "$AGW_EDITION" != "oss" && -z "${AGENTGATEWAY_LICENSE_KEY:-}" ]]; then
    die "AGENTGATEWAY_LICENSE_KEY not set — export it, point SECRETS_FILE at a file that does, or run with AGW_EDITION=oss"
  fi
}

# ── kubectl helpers ───────────────────────────────────────────────────────────
kc() { kubectl --context "$CTX" "$@"; }

check_docker() {
  docker info >/dev/null 2>&1 || die "docker daemon not reachable — start Docker Desktop / OrbStack"
}

wait_deploy() {
  local ns="$1" name="$2" timeout="${3:-180s}"
  local end=$(( $(date +%s) + 180 ))
  until kc -n "$ns" get deployment "$name" >/dev/null 2>&1; do
    [[ $(date +%s) -ge $end ]] && { warn "deployment $ns/$name not created within 3m"; return 1; }
    sleep 3
  done
  kc -n "$ns" wait --for=condition=Available deployment/"$name" --timeout="$timeout" >/dev/null
}
