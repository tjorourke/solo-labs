#!/usr/bin/env bash
# lib.sh — shared helpers for agent-harness-openclaw-kind. Sourced by every script here.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
YAML="$LAB_DIR/yaml"
CAPTURES="$LAB_DIR/captures"
RUNTIME="$LAB_DIR/.runtime"          # gitignored: OpenClaw source checkout, config, workspace
export SCRIPT_DIR LAB_DIR YAML CAPTURES RUNTIME

# shellcheck source=../versions.env
. "$LAB_DIR/versions.env"
export OPENCLAW_VERSION OPENCLAW_IMAGE KAGENT_VERSION SUBSTRATE_VERSION ATEOM_IMAGE
export KIND_NODE_IMAGE GATEWAY_API_VERSION AGENTGATEWAY_VERSION MODEL_PROVIDER MODEL_NAME

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

require() { command -v "$1" >/dev/null 2>&1 || die "$1 not found: install it first"; }

# ── names ─────────────────────────────────────────────────────────────────────
export CLUSTER_NAME="${CLUSTER_NAME:-openclaw-harness}"
export CTX="kind-${CLUSTER_NAME}"
export NS=kagent
export ATE_NS=ate-system
export AGW_NS=agentgateway-system
export SRE_NS=sre-lab
export HARNESS=openclaw-lab
export WORKER_POOL=kagent-default
export MODEL_SECRET=kagent-anthropic          # the real key, read by kagent's default ModelConfig
export GATEWAY_NAME=openclaw-gateway
export GATEWAY_HOST="${GATEWAY_NAME}.${AGW_NS}.svc.cluster.local"
export BASELINE_PROJECT=openclaw-baseline     # docker compose project for the OpenClaw 2.0 baseline
export BASELINE_CONTAINER="${BASELINE_PROJECT}-openclaw-gateway-1"

# ── secrets ───────────────────────────────────────────────────────────────────
SECRETS_FILE="${SECRETS_FILE:-$HOME/code/solo/secrets/secrets-envs.sh}"
load_secrets() { if [[ -f "$SECRETS_FILE" ]]; then set -a; . "$SECRETS_FILE"; set +a; fi; }
require_secrets() {
  [[ -n "${ANTHROPIC_API_KEY:-}" ]] || load_secrets
  [[ -n "${ANTHROPIC_API_KEY:-}" ]] || die "ANTHROPIC_API_KEY is not set. export it, or put it in $SECRETS_FILE"
}

# ── kubectl / helm ────────────────────────────────────────────────────────────
kc() { kubectl --context "$CTX" "$@"; }
check_docker() { docker info >/dev/null 2>&1 || die "docker daemon not reachable"; }

wait_deploy() {
  local ns="$1" name="$2" timeout="${3:-300s}"
  local end=$(( $(date +%s) + 180 ))
  until kc -n "$ns" get deployment "$name" >/dev/null 2>&1; do
    [[ $(date +%s) -ge $end ]] && { warn "deployment $ns/$name not created within 3m"; return 1; }
    sleep 3
  done
  kc -n "$ns" wait --for=condition=Available deployment/"$name" --timeout="$timeout" >/dev/null
}

condition() { # condition <kind/name> <type> -> True|False|""
  kc -n "$NS" get "$1" -o jsonpath="{.status.conditions[?(@.type==\"$2\")].status}" 2>/dev/null
}
condition_msg() {
  kc -n "$NS" get "$1" -o jsonpath="{.status.conditions[?(@.type==\"$2\")].message}" 2>/dev/null
}

# helm upgrade --install that prints pod snapshots while it blocks.
helm_install_with_progress() {
  local release="$1" chart="$2" namespace="$3"
  shift 3
  helm --kube-context "$CTX" upgrade --install "$release" "$chart" \
    --namespace "$namespace" --create-namespace "$@" >/dev/null &
  local helm_pid=$! start
  start=$(date +%s)
  while kill -0 "$helm_pid" 2>/dev/null; do
    sleep 15
    kill -0 "$helm_pid" 2>/dev/null || break
    local elapsed=$(( $(date +%s) - start )) pods_summary
    pods_summary=$(kc -n "$namespace" get pods --no-headers 2>/dev/null | awk '{printf "%s[%s] ", $1, $2}')
    if [[ -n "$pods_summary" ]]; then log "[+${elapsed}s] pods: ${pods_summary}"; else log "[+${elapsed}s] pulling images / creating pods..."; fi
  done
  wait "$helm_pid"
}

# ── kagent controller port-forward (the ACP path and the substrate inventory) ─
export CONTROLLER_PORT="${CONTROLLER_PORT:-18083}"
export CONTROLLER_URL="http://127.0.0.1:${CONTROLLER_PORT}"
export UI_PORT="${UI_PORT:-18080}"
export GATEWAY_PORT="${GATEWAY_PORT:-18090}"     # local port for the agentgateway Service

__start_pf() { # __start_pf <svc> <local> <remote> <health url> <ns>
  local svc="$1" lport="$2" rport="$3" url="$4" ns="${5:-$NS}"
  pkill -f "port-forward .*${svc} ${lport}:${rport}" 2>/dev/null || true
  nohup kubectl --context "$CTX" -n "$ns" port-forward "$svc" "${lport}:${rport}" >/dev/null 2>&1 </dev/null &
  local i
  for i in $(seq 1 30); do
    curl -s -m 2 -o /dev/null "$url" 2>/dev/null && return 0
    sleep 1
  done
  return 1
}
controller_pf() {
  curl -s -m 2 -o /dev/null "$CONTROLLER_URL/health" 2>/dev/null && return 0
  __start_pf svc/kagent-controller "$CONTROLLER_PORT" 8083 "$CONTROLLER_URL/health" || die "cannot reach kagent-controller on $CONTROLLER_URL"
}
gateway_pf() {
  curl -s -m 2 -o /dev/null "http://127.0.0.1:${GATEWAY_PORT}/" 2>/dev/null && return 0
  __start_pf "svc/${GATEWAY_NAME}" "$GATEWAY_PORT" 80 "http://127.0.0.1:${GATEWAY_PORT}/" "$AGW_NS" || die "cannot reach ${GATEWAY_NAME} on :${GATEWAY_PORT}"
}
pf_down() {
  pkill -f "port-forward .*kagent-controller ${CONTROLLER_PORT}:8083" 2>/dev/null || true
  pkill -f "port-forward .*kagent-ui ${UI_PORT}:8080" 2>/dev/null || true
  pkill -f "port-forward .*${GATEWAY_NAME} ${GATEWAY_PORT}:80" 2>/dev/null || true
}

# substrate inventory as kagent sees it: workers and actors
substrate_status() { controller_pf; curl -s --max-time 15 "$CONTROLLER_URL/api/substrate/status"; }
