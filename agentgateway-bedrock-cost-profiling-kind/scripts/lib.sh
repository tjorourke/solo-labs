#!/usr/bin/env bash
# lib.sh — shared helpers for the agentgateway-bedrock-cost-profiling-kind lab.
# A single kind cluster running Solo Enterprise for agentgateway. The gateway
# fronts Amazon Bedrock via the native `bedrock` provider (SigV4 / Converse).
# Each team is given its own AWS *application inference profile* (cost-allocation
# tagged); clients send the team's profile ARN as the model. Token usage is then
# attributable per team two ways: AWS Cost Explorer (by tag) and agentgateway's
# gen_ai_request_model metric label (by ARN).

set -Eeuo pipefail

# Central product/infra versions (generated from versions.json). A bump in one
# place flows to every lab; runtime env still wins. := fallbacks keep this
# runnable if the dir is copied out standalone.
__versions_env="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/versions.env"
[ -f "$__versions_env" ] && . "$__versions_env"
: "${AGW_ENT_VERSION:=v2.3.4}"

# EXPLICIT PIN (versions.json allows per-lab exceptions in lib.sh): this lab is
# built and verified on AGW v2026.5.1 for the Bedrock Converse flow. Re-validate
# and bump when moving the lab to a newer build.
export AGW_VERSION="${AGW_VERSION:-v2026.5.1}"

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
export CLUSTER="${CLUSTER:-bedrock-cost-agw}"
export CTX="kind-${CLUSTER}"
export GW_NS="${GW_NS:-agentgateway-system}"
export GW_NAME="${GW_NAME:-agentgateway-proxy}"
export PORT="${PORT:-8080}"
export LPORT="${LPORT:-18080}"
export MPORT="${MPORT:-15020}"

# ── enterprise agentgateway chart ─────────────────────────────────────────────
export AGW_VERSION="${AGW_VERSION:-$AGW_ENT_VERSION}"
export GAR_HOST="${GAR_HOST:-us-docker.pkg.dev}"
export AGW_REGISTRY="${AGW_REGISTRY:-oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts}"
export AGW_CHART="${AGW_CHART:-${AGW_REGISTRY}/enterprise-agentgateway}"
export AGW_CRDS_CHART="${AGW_CRDS_CHART:-${AGW_REGISTRY}/enterprise-agentgateway-crds}"
export GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.5.1}"

# ── AWS / Bedrock ─────────────────────────────────────────────────────────────
# Region is pinned for the lab (overridable with REGION=...). It is deliberately
# NOT inherited from a personal AWS_REGION: in some regions the cross-region
# system inference profiles are owned by an AWS-managed account, so application
# profiles copied from them land out-of-account and can't be invoked. us-east-1
# keeps the system profiles in your own account.
export REGION="${REGION:-us-east-1}"
export NS="${NS:-bedrock-cost}"            # app namespace for the backend/route
export SECRET="${SECRET:-bedrock-secret}"  # AWS creds Secret consumed by the backend
# Teams to profile. Each becomes one AWS application inference profile.
export TEAMS="${TEAMS:-finance engineering}"
# JWT identity (Pattern A): the gateway mints/validates RS256 tokens whose `team`
# claim selects the team's backend. iss/aud must match the jwtAuthentication policy.
export JWT_ISSUER="${JWT_ISSUER:-bedrock-cost-lab}"
export JWT_AUDIENCE="${JWT_AUDIENCE:-bedrock-api}"
export JWT_KID="${JWT_KID:-bedrock-cost-key}"
# Base model the per-team application profiles copy from (a working, current model).
export BASE_MODEL="${BASE_MODEL:-us.anthropic.claude-haiku-4-5-20251001-v1:0}"
export RESULTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/results"

# ── secrets ───────────────────────────────────────────────────────────────────
# AGENTGATEWAY_LICENSE_KEY — Solo Enterprise agentgateway license.
# Provide via env, or SECRETS_FILE=/path/to/secrets.sh (sourced).
load_secrets() {
  if [[ -n "${SECRETS_FILE:-}" ]]; then
    [[ -f "$SECRETS_FILE" ]] || die "SECRETS_FILE='$SECRETS_FILE' does not exist"
    set -a; source "$SECRETS_FILE"; set +a
  elif [[ -f "$HOME/code/solo/secrets/secrets-envs.sh" ]]; then
    set -a; source "$HOME/code/solo/secrets/secrets-envs.sh"; set +a
  fi
  # The lab's REGION is authoritative — force the CLI/SDK to match it, overriding
  # any AWS_REGION the secrets file set, so we always act in the pinned region.
  export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"
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

require_aws() {
  load_secrets
  require aws
  aws sts get-caller-identity >/dev/null 2>&1 || die "AWS creds not valid. Run: aws sso login --profile \$AWS_PROFILE (or set AWS_PROFILE)"
}

# ── kubectl helpers ───────────────────────────────────────────────────────────
kctx() { kubectl --context "$CTX" "$@"; }
check_docker() { docker info >/dev/null 2>&1 || die "docker daemon not reachable — start Docker Desktop / OrbStack"; }

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
    local pods; pods=$(kctx -n "$namespace" get pods --no-headers 2>/dev/null | awk '{printf "%s[%s] ", $1, $2}')
    [[ -n "$pods" ]] && log "[+${elapsed}s] pods: ${pods}" || log "[+${elapsed}s] pulling images..."
  done
  wait "$helm_pid"
}
