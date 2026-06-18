#!/usr/bin/env bash
# lib.sh — shared helpers for agent-harness-openshell-kind scripts.
#
# Sourced by every script under ./scripts/. Mirrors the agentic-budgets-kind and
# agentic-hitl-kind labs so the family shares muscle memory.

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
export CLUSTER_NAME="${CLUSTER_NAME:-harness}"
export CTX="kind-${CLUSTER_NAME}"

export GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.4.0}"

# kagent OSS — anonymous OCI pull, no auth. AgentHarness CRD landed in 0.9.2;
# empty version = chart default (currently 0.9.x line).
export KAGENT_VERSION="${KAGENT_VERSION:-}"
export KAGENT_CRDS_CHART="${KAGENT_CRDS_CHART:-oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds}"
export KAGENT_CHART="${KAGENT_CHART:-oci://ghcr.io/kagent-dev/kagent/helm/kagent}"

# OpenShell — the sandbox gateway the AgentHarness backend talks to.
# (NVIDIA OpenShell helm chart; anonymous OCI pull.)
export OPENSHELL_VERSION="${OPENSHELL_VERSION:-0.0.49}"
export OPENSHELL_CHART="${OPENSHELL_CHART:-oci://ghcr.io/nvidia/openshell/helm-chart}"
export OPENSHELL_NS="${OPENSHELL_NS:-openshell}"
# Pin the generated resource name so the Service lands at a clean DNS name the
# kagent controller can target (openshell.openshell.svc.cluster.local:8080).
export OPENSHELL_FULLNAME="${OPENSHELL_FULLNAME:-openshell}"
# The agent-sandbox controller (sandboxes.agents.x-k8s.io) OpenShell builds on.
export AGENT_SANDBOX_MANIFEST="${AGENT_SANDBOX_MANIFEST:-https://raw.githubusercontent.com/NVIDIA/OpenShell/refs/heads/main/deploy/kube/manifests/agent-sandbox.yaml}"

# The gRPC target the kagent controller uses to reach the OpenShell gateway.
export OPENSHELL_GRPC_ADDR="${OPENSHELL_GRPC_ADDR:-${OPENSHELL_FULLNAME}.${OPENSHELL_NS}.svc.cluster.local:8080}"

# ── secrets loader ────────────────────────────────────────────────────────────
# Required: ANTHROPIC_API_KEY (kagent default model + the OpenClaw harness agent).
# Optional: SLACK_WEBHOOK_URL — a Slack Incoming Webhook the agent uses to
#           escalate when it is NOT permitted to fix a namespace. If unset, the
#           escalation path simply reports in the agent's reply instead of Slack.
# Export them directly or point SECRETS_FILE at a sourceable file.
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

ERROR: missing required env var: ANTHROPIC_API_KEY

Two ways to provide it:
  1. export in your current shell:
       export ANTHROPIC_API_KEY=sk-ant-...
       ./scripts/quick.sh up

  2. point at a sourceable file:
       SECRETS_FILE=/path/to/secrets.sh ./scripts/quick.sh up

  Anthropic key:  https://console.anthropic.com/
EOF
    exit 1
  fi
}

# ── kubectl / helm helpers ────────────────────────────────────────────────────
kc() { kubectl --context "$CTX" "$@"; }

check_docker() {
  docker info >/dev/null 2>&1 || die "docker daemon not reachable — start Docker Desktop / OrbStack"
}

# Poll for a deployment to exist (operator may create it asynchronously) and then
# for it to become Available.
wait_deploy() {
  local ns="$1" name="$2" timeout="${3:-300s}"
  local end=$(( $(date +%s) + 180 ))
  until kc -n "$ns" get deployment "$name" >/dev/null 2>&1; do
    [[ $(date +%s) -ge $end ]] && { warn "deployment $ns/$name not created within 3m"; return 1; }
    sleep 3
  done
  kc -n "$ns" wait --for=condition=Available deployment/"$name" --timeout="$timeout" >/dev/null
}

# Wait for all pods matching a label selector to be Ready.
wait_pods_ready() {
  local ns="$1" selector="$2" timeout="${3:-300s}"
  local end=$(( $(date +%s) + 180 ))
  until [[ -n "$(kc -n "$ns" get pods -l "$selector" --no-headers 2>/dev/null)" ]]; do
    [[ $(date +%s) -ge $end ]] && { warn "no pods matched $selector in $ns within 3m"; return 1; }
    sleep 3
  done
  kc -n "$ns" wait --for=condition=Ready pod -l "$selector" --timeout="$timeout" >/dev/null
}

# find_sandbox — locate the OpenShell-provisioned sandbox the harness created.
# Prints "<namespace> <pod> <serviceaccount>" on success; returns 1 if not found.
# The sandbox is an agent-sandbox (sandboxes.agents.x-k8s.io) backing the harness.
find_sandbox() {
  local ns name pod sa
  kc get crd sandboxes.agents.x-k8s.io >/dev/null 2>&1 || return 1
  ns="$(kc get sandboxes.agents.x-k8s.io -A -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null)"
  name="$(kc get sandboxes.agents.x-k8s.io -A -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  [[ -z "$ns" ]] && return 1
  # The sandbox pod name equals the Sandbox resource name; the pod label is a
  # name-hash, not the name, so match by name (with a substring fallback).
  pod="$(kc -n "$ns" get pod "$name" -o name 2>/dev/null | sed 's#pod/##')"
  [[ -z "$pod" ]] && pod="$(kc -n "$ns" get pod -o name 2>/dev/null | sed 's#pod/##' | grep -F "$name" | head -1)"
  [[ -z "$pod" ]] && return 1
  sa="$(kc -n "$ns" get pod "$pod" -o jsonpath='{.spec.serviceAccountName}' 2>/dev/null)"
  echo "$ns $pod ${sa:-default}"
}

# helm upgrade --install that prints periodic pod-status snapshots while it
# blocks (bare --wait is silent for minutes on cold clusters / image pulls).
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
