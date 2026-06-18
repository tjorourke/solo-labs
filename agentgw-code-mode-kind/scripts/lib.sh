#!/usr/bin/env bash
# lib.sh — shared helpers for agentgw-code-mode-kind.
#
# Demonstrates agentgateway "code mode": an OpenAPI backend (the public Swagger
# petstore) exposed through EnterpriseAgentgatewayBackend with toolMode: Code,
# so the gateway hands the client a single run_code tool plus a generated
# TypeScript API and runs model-written JavaScript in a sandbox.

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
log()  { { __dim "  $*"; printf '\n'; } >&2; }
ok()   { { __ok "$*";    printf '\n'; } >&2; }
warn() { { __warn "$*";  printf '\n'; } >&2; }
die()  { { __err "$*";   printf '\n'; } >&2; exit 1; }
step() { printf '\n' >&2; { __step "══> $*"; printf '\n'; } >&2; }
require() { command -v "$1" >/dev/null 2>&1 || die "$1 not found — install it first"; }

# ── cluster constants ─────────────────────────────────────────────────────────
export CLUSTER_NAME="${CLUSTER_NAME:-code-mode}"
export CTX="kind-${CLUSTER_NAME}"

# Enterprise agentgateway. Code mode (entMcp.toolMode: Code, the run_code tool +
# JS sandbox) ships in the CalVer line — present since the first CalVer release
# v2026.5.0, and absent from the older SemVer 2.3.x backend. Pin v2026.5.2, the
# latest monthly at time of writing.
export AGW_VERSION="${AGW_VERSION:-$AGW_CALVER_VERSION}"
export AGW_REGISTRY="${AGW_REGISTRY:-oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts}"
export AGW_GAR_HOST="${AGW_GAR_HOST:-us-docker.pkg.dev}"
export AGW_CHART="${AGW_CHART:-${AGW_REGISTRY}/enterprise-agentgateway}"
export AGW_CRDS_CHART="${AGW_CRDS_CHART:-${AGW_REGISTRY}/enterprise-agentgateway-crds}"

export METALLB_VERSION="${METALLB_VERSION:-v0.14.9}"
export GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.4.0}"

# Namespace everything lives in, and the MCP path the gateway serves.
export AGW_NS="${AGW_NS:-agentgateway-system}"
export GATEWAY_NAME="${GATEWAY_NAME:-code-mode-gateway}"
export MCP_PATH="${MCP_PATH:-/mcp}"

# The petstore publishes its own OpenAPI document. The lab loads THAT into the
# ConfigMap (it is not hand-authored). yaml/petstore-openapi.json is a pinned
# copy used as a fallback when the published URL is unreachable (airgap/offline).
export PETSTORE_OPENAPI_URL="${PETSTORE_OPENAPI_URL:-https://petstore3.swagger.io/api/v3/openapi.json}"

# ── secrets ───────────────────────────────────────────────────────────────────
# Bringing the cluster up needs only the AGW license. The LLM demo (ask-llm.sh)
# additionally needs ANTHROPIC_API_KEY, checked there.
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

ERROR: missing AGENTGATEWAY_LICENSE_KEY (Solo Enterprise agentgateway license).

  export AGENTGATEWAY_LICENSE_KEY=...
  ./scripts/quick.sh up

  or:  SECRETS_FILE=/path/to/secrets.sh ./scripts/quick.sh up

  License: ask your Solo account team.
  (The LLM demo also needs ANTHROPIC_API_KEY — see ./scripts/ask-llm.sh.)
EOF
    exit 1
  fi
}

# ── kubectl + cluster helpers ─────────────────────────────────────────────────
kc() { kubectl --context "$CTX" "$@"; }

check_docker() { docker info >/dev/null 2>&1 || die "docker daemon not reachable — start Docker Desktop / OrbStack"; }

wait_deploy() {
  local ns="$1" name="$2" timeout="${3:-300s}"
  local end=$(( $(date +%s) + 120 ))
  until kc -n "$ns" get deployment "$name" >/dev/null 2>&1; do
    [[ $(date +%s) -ge $end ]] && { warn "deployment $ns/$name not created within 2m"; return 1; }
    sleep 3
  done
  kc -n "$ns" wait --for=condition=Available deployment/"$name" --timeout="$timeout" >/dev/null
}

# ensure_gar_auth — idempotent gcloud + docker + helm OCI auth for a Google
# Artifact Registry host. The Solo chart repo is public but helm OCI pull still
# returns 401 without a gcloud-token-backed `helm registry login`.
ensure_gar_auth() {
  local host="$1"
  command -v gcloud >/dev/null 2>&1 || die "gcloud required for the Solo chart at $host. Install: brew install --cask google-cloud-sdk; gcloud auth login"
  if ! gcloud auth print-access-token >/dev/null 2>&1; then
    [[ -t 0 ]] || die "gcloud not authenticated and no TTY. Run: gcloud auth login"
    gcloud auth login || die "gcloud auth login failed"
  fi
  if ! grep -q "\"${host}\":" "$HOME/.docker/config.json" 2>/dev/null; then
    log "configuring docker credential helper for $host"
    gcloud auth configure-docker --quiet "$host" >/dev/null
  fi
  log "helm registry login → $host"
  gcloud auth print-access-token \
    | helm registry login -u oauth2accesstoken --password-stdin "$host" >/dev/null \
    || die "helm registry login failed for $host (on macOS click 'Always Allow' on the Keychain prompt, then re-run)"
}

# helm_install_with_progress — helm upgrade --install --wait with periodic pod
# snapshots so a cold-pull install does not look hung.
helm_install_with_progress() {
  local release="$1" chart="$2" namespace="$3"; shift 3
  helm --kube-context "$CTX" upgrade --install "$release" "$chart" \
    --namespace "$namespace" --create-namespace "$@" >/dev/null &
  local pid=$!; local start; start=$(date +%s)
  while kill -0 "$pid" 2>/dev/null; do
    sleep 15; kill -0 "$pid" 2>/dev/null || break
    local e=$(( $(date +%s) - start ))
    local p; p=$(kc -n "$namespace" get pods --no-headers 2>/dev/null | awk '{printf "%s[%s] ", $1, $2}')
    [[ -n "$p" ]] && log "[+${e}s] pods: ${p}" || log "[+${e}s] pulling images / creating pods..."
  done
  wait "$pid"
}

# gateway_service — name of the Service the AGW deployer created for our Gateway.
gateway_service() {
  kc -n "$AGW_NS" get svc -l "gateway.networking.k8s.io/gateway-name=${GATEWAY_NAME}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# ── MCP endpoint helpers ──────────────────────────────────────────────────────
# High, uncommon local port on purpose: low ports like 8080 are routinely
# squatted by other tools (and stay below the 32768 ephemeral range so the OS
# won't grab it for an outbound connection).
export MCP_LOCAL_PORT="${MCP_LOCAL_PORT:-18770}"
export MCP_URL="${MCP_URL:-http://localhost:${MCP_LOCAL_PORT}${MCP_PATH}}"

# ensure_gw_pf — start a background port-forward (gateway Service :80 → local
# port) unless MCP_URL already points somewhere reachable. Sets GW_PF_PID and
# installs an EXIT trap so the demo scripts can be run one-shot. Idempotent-ish:
# if the local port already answers, it reuses it.
ensure_gw_pf() {
  local lport="${MCP_LOCAL_PORT}"
  if curl -s -o /dev/null --max-time 2 "http://localhost:${lport}/"; then
    log "reusing existing forward on localhost:${lport}"
    return 0
  fi
  local svc; svc="$(gateway_service)"
  [[ -n "$svc" ]] || die "gateway Service not found — is the lab up? (./scripts/quick.sh status)"
  kc -n "$AGW_NS" port-forward "svc/${svc}" "${lport}:80" >/tmp/code-mode-gw-pf.$$ 2>&1 &
  GW_PF_PID=$!
  trap 'kill "${GW_PF_PID}" 2>/dev/null' EXIT
  for _ in $(seq 1 30); do
    curl -s -o /dev/null --max-time 2 "http://localhost:${lport}/" && { ok "gateway → localhost:${lport}"; return 0; }
    sleep 1
  done
  die "gateway port-forward to localhost:${lport} did not come up"
}

# uv_run — run a demo python client (PEP 723 inline deps via uv) from scripts/py.
uv_run() {
  require uv
  local py="$1"; shift
  ( cd "$(dirname "${BASH_SOURCE[0]}")/py" && MCP_URL="$MCP_URL" uv run --quiet "$py" "$@" )
}
