#!/usr/bin/env bash
# lib.sh — shared settings for agentgateway-inference-disaggregation-eks.
#
# This lab LAYERS on agentgateway-inference-load-balancing-eks. It builds no
# infrastructure: same cluster, same two GPU cards, same weights on the same volumes,
# same Gateway. What it changes is what runs on the cards and which Endpoint Picker
# decides where a request goes.
#
# Edition: nothing here touches the gateway's configuration at all, so whichever edition
# of agentgateway is already installed keeps working unchanged.
set -Eeuo pipefail

__versions_env="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/versions.env"
[ -f "$__versions_env" ] && . "$__versions_env"
: "${LLMD_SCHEDULER_VERSION:=v0.10.0}"

__has_color() { [[ -t 2 ]] && command -v tput >/dev/null 2>&1; }
if __has_color; then
  __dim()  { tput dim;  printf '%s' "$*"; tput sgr0; }
  __ok()   { tput setaf 2; printf '✓ '; tput sgr0; printf '%s' "$*"; }
  __warn() { tput setaf 3; printf '! '; tput sgr0; printf '%s' "$*"; }
  __err()  { tput setaf 1; printf 'ERROR: '; tput sgr0; printf '%s' "$*"; }
  __step() { tput bold; printf '%s' "$*"; tput sgr0; }
else
  __dim()  { printf '%s' "$*"; }; __ok() { printf '✓ %s' "$*"; }
  __warn() { printf '! %s' "$*"; }; __err() { printf 'ERROR: %s' "$*"; }
  __step() { printf '%s' "$*"; }
fi
log()  { { __dim "  $*"; printf '\n'; } >&2; }
ok()   { { __ok "$*";    printf '\n'; } >&2; }
warn() { { __warn "$*";  printf '\n'; } >&2; }
die()  { { __err "$*";   printf '\n'; } >&2; exit 1; }
step() { printf '\n' >&2; { __step "══> $*"; printf '\n'; } >&2; }
require() { command -v "$1" >/dev/null 2>&1 || die "$1 not found — install it first"; }

export LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The lab this one layers on, so its manifests can be re-applied on restore.
export BASE_LAB="${BASE_LAB:-$(cd "$LAB_ROOT/../agentgateway-inference-load-balancing-eks" 2>/dev/null && pwd)}"
export EKS_CLUSTER="${EKS_CLUSTER:-inference-lb}"
export AWS_REGION="${AWS_REGION:-eu-west-2}"
export NS="${NS:-models}"
export MODEL_NAME="${MODEL_NAME:-qwen3-coder-30b}"

resolve_ctx() {
  if [ -n "${KUBE_CONTEXT:-}" ]; then CTX="$KUBE_CONTEXT"; export CTX; return; fi
  local region account arn found cluster_entry
  region="$AWS_REGION"
  account="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
  [ -n "$account" ] && [ "$account" != "None" ] \
    || die "no AWS identity. Check AWS_PROFILE, or run aws sso login."
  arn="arn:aws:eks:${region}:${account}:cluster/${EKS_CLUSTER}"
  if command kubectl config get-contexts -o name 2>/dev/null | grep -qxF "$arn"; then
    CTX="$arn"; export CTX; return
  fi
  for cluster_entry in "$arn" "${EKS_CLUSTER}.${region}.eksctl.io"; do
    found="$(command kubectl config view -o \
      "jsonpath={range .contexts[?(@.context.cluster=='${cluster_entry}')]}{.name}{'\n'}{end}" 2>/dev/null | head -1)"
    if [ -n "$found" ]; then CTX="$found"; export CTX; return; fi
  done
  log "no kubectl context for $EKS_CLUSTER; writing one with aws eks update-kubeconfig"
  aws eks update-kubeconfig --region "$region" --name "$EKS_CLUSTER" >/dev/null
  CTX="$arn"; export CTX
}

kc() { kubectl --context "$CTX" "$@"; }
