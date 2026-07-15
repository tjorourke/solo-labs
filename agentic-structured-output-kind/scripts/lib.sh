#!/usr/bin/env bash
# lib.sh — shared helpers for agentic-structured-output-kind.
# OSS kagent on a single kind cluster. The only secret needed is ANTHROPIC_API_KEY.

set -Eeuo pipefail

__has_color() { [[ -t 2 ]] && command -v tput >/dev/null 2>&1; }
if __has_color; then
  __dim(){ tput dim;printf '%s' "$*";tput sgr0;}; __ok(){ tput setaf 2;printf '✓ ';tput sgr0;printf '%s' "$*";}
  __warn(){ tput setaf 3;printf '! ';tput sgr0;printf '%s' "$*";}; __err(){ tput setaf 1;printf 'ERROR: ';tput sgr0;printf '%s' "$*";}
  __step(){ tput bold;printf '%s' "$*";tput sgr0;}
else
  __dim(){ printf '%s' "$*";}; __ok(){ printf '✓ %s' "$*";}; __warn(){ printf '! %s' "$*";}; __err(){ printf 'ERROR: %s' "$*";}; __step(){ printf '%s' "$*";}
fi
log(){ { __dim "  $*";printf '\n';} >&2; }
ok(){ { __ok "$*";printf '\n';} >&2; }
warn(){ { __warn "$*";printf '\n';} >&2; }
die(){ { __err "$*";printf '\n';} >&2; exit 1; }
step(){ printf '\n' >&2; { __step "══> $*";printf '\n';} >&2; }
require(){ command -v "$1" >/dev/null 2>&1 || die "$1 not found — install it first"; }

export CLUSTER_NAME="${CLUSTER_NAME:-agent-contract}"
export CTX="kind-${CLUSTER_NAME}"

# OSS kagent (latest at time of build). CRDs + app share the version.
export KAGENT_VERSION="${KAGENT_VERSION:-0.9.4}"
export KAGENT_CRDS_CHART="${KAGENT_CRDS_CHART:-oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds}"
export KAGENT_CHART="${KAGENT_CHART:-oci://ghcr.io/kagent-dev/kagent/helm/kagent}"
# The kagent-adk base image the BYO Dockerfile builds on. Tag tracks KAGENT_VERSION
# (ghcr tags have no leading v, e.g. kagent-adk:0.9.4).
export KAGENT_ADK_VERSION="${KAGENT_ADK_VERSION:-${KAGENT_VERSION}}"

# Local image tags loaded into kind (never pulled — imagePullPolicy: IfNotPresent).
export RECORD_TOOLS_IMAGE="${RECORD_TOOLS_IMAGE:-record-tools:dev}"
export DBA_ADK_IMAGE="${DBA_ADK_IMAGE:-dba-adk:dev}"

# The Anthropic model the agents use (declarative ModelConfig + BYO LiteLlm).
export KAGENT_MODEL="${KAGENT_MODEL:-claude-sonnet-4-5-20250929}"

kc(){ kubectl --context "$CTX" "$@"; }
check_docker(){ docker info >/dev/null 2>&1 || die "docker daemon not reachable"; }

# Load ANTHROPIC_API_KEY from SECRETS_FILE if set, then require it.
load_secrets() {
  if [[ -n "${SECRETS_FILE:-}" ]]; then
    [[ -f "$SECRETS_FILE" ]] || die "SECRETS_FILE='$SECRETS_FILE' does not exist"
    set -a; source "$SECRETS_FILE"; set +a
  fi
}
require_secrets() {
  load_secrets
  [[ -n "${ANTHROPIC_API_KEY:-}" ]] || cat >&2 <<'EOF'

ERROR: missing ANTHROPIC_API_KEY

  export ANTHROPIC_API_KEY=sk-ant-...
  ./scripts/quick.sh up

  or:  SECRETS_FILE=/path/to/secrets.sh ./scripts/quick.sh up
EOF
  [[ -n "${ANTHROPIC_API_KEY:-}" ]] || exit 1
}

wait_deploy() {
  local ns="$1" name="$2" timeout="${3:-300s}"; local end=$(( $(date +%s) + 240 ))
  until kc -n "$ns" get deployment "$name" >/dev/null 2>&1; do
    [[ $(date +%s) -ge $end ]] && { warn "deployment $ns/$name not created in 4m"; return 1; }; sleep 3
  done
  kc -n "$ns" wait --for=condition=Available deployment/"$name" --timeout="$timeout" >/dev/null
}
wait_agent() {
  local name="$1" timeout="${2:-300}"; local end=$(( $(date +%s) + timeout ))
  until [[ "$(kc -n kagent get agent "$name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == "True" ]]; do
    [[ $(date +%s) -ge $end ]] && { warn "agent $name not Ready in ${timeout}s"; return 1; }; sleep 5
  done
}

helm_install_with_progress() {
  local release="$1" chart="$2" namespace="$3"; shift 3
  helm --kube-context "$CTX" upgrade --install "$release" "$chart" --namespace "$namespace" --create-namespace "$@" >/dev/null &
  local pid=$!; local start; start=$(date +%s)
  while kill -0 "$pid" 2>/dev/null; do
    sleep 15; kill -0 "$pid" 2>/dev/null || break
    local e=$(( $(date +%s) - start )); local p; p=$(kc -n "$namespace" get pods --no-headers 2>/dev/null | awk '{printf "%s[%s] ",$1,$2}')
    [[ -n "$p" ]] && log "[+${e}s] pods: ${p}" || log "[+${e}s] pulling images / creating pods..."
  done
  wait "$pid"
}
