#!/usr/bin/env bash
# lib.sh — shared settings and helpers for agentgateway-inference-load-balancing-eks.
#
# One EKS cluster, two GPU cards, one model on both of them, and a gateway that has to
# decide which card takes the next request. Everything in this lab is about that one
# decision.
#
# Edition: nothing here needs Enterprise. InferencePool routing is on both editions
# (inferenceExtension.enabled on the gateway chart), and the manifests in yaml/ use only
# the shared agentgateway.dev and Gateway API Inference Extension APIs. The only
# per-edition difference is the GatewayClass name, substituted at apply time, and the
# Helm chart and registry. Default is OSS; AGW_EDITION=enterprise runs the Solo build
# and needs a licence.

set -Eeuo pipefail

# Central product/infra versions (generated from versions.json). Runtime env still wins;
# the := fallbacks keep the lab runnable if versions.env is absent.
__versions_env="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/versions.env"
[ -f "$__versions_env" ] && . "$__versions_env"
: "${AGW_ENT_VERSION:=v2.3.7}"
: "${AGW_OSS_VERSION:=v1.5.0}"
: "${GATEWAY_API_VERSION:=v1.5.1}"
: "${GIE_VERSION:=v1.4.0}"

# ── logging ───────────────────────────────────────────────────────────────────────────
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

# ── names ─────────────────────────────────────────────────────────────────────────────
export LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export EKS_CLUSTER="${EKS_CLUSTER:-inference-lb}"
export AWS_REGION="${AWS_REGION:-eu-west-2}"
export GPU_NODEGROUP="${GPU_NODEGROUP:-gpu}"
export NS="${NS:-models}"
export AGW_NS="${AGW_NS:-agentgateway-system}"
export MODEL_NAME="${MODEL_NAME:-qwen3-coder-30b}"
# The Helm release name becomes the InferencePool name, and the EPP is <release>-epp.
# Deliberately NOT `vllm`: that is the Service name, and a pool and a Service sharing a
# name turns a dropped backendRef group into silent round-robin. See yaml/11.
export POOL_RELEASE="${POOL_RELEASE:-vllm-pool}"

# ── edition ───────────────────────────────────────────────────────────────────────────
export AGW_EDITION="${AGW_EDITION:-oss}"
if [[ "$AGW_EDITION" == "enterprise" ]]; then
  export AGW_VERSION="${AGW_VERSION:-$AGW_ENT_VERSION}"
  export AGW_CRDS_CHART="${AGW_CRDS_CHART:-oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds}"
  export AGW_CHART="${AGW_CHART:-oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway}"
  export GATEWAY_CLASS="${GATEWAY_CLASS:-enterprise-agentgateway}"
else
  export AGW_VERSION="${AGW_VERSION:-$AGW_OSS_VERSION}"
  export AGW_CRDS_CHART="${AGW_CRDS_CHART:-oci://cr.agentgateway.dev/charts/agentgateway-crds}"
  export AGW_CHART="${AGW_CHART:-oci://cr.agentgateway.dev/charts/agentgateway}"
  export GATEWAY_CLASS="${GATEWAY_CLASS:-agentgateway}"
fi

export GIE_POOL_CHART="${GIE_POOL_CHART:-oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool}"

# ── secrets ───────────────────────────────────────────────────────────────────────────
# Only Enterprise needs anything. OSS needs nothing at all.
load_secrets() {
  if [[ -n "${SECRETS_FILE:-}" ]]; then
    [[ -f "$SECRETS_FILE" ]] || die "SECRETS_FILE='$SECRETS_FILE' does not exist"
    set -a; source "$SECRETS_FILE"; set +a
  fi
}

require_secrets() {
  load_secrets
  if [[ "$AGW_EDITION" == "enterprise" && -z "${AGENTGATEWAY_LICENSE_KEY:-}" ]]; then
    die "AGENTGATEWAY_LICENSE_KEY not set — export it, point SECRETS_FILE at a file that does, or leave AGW_EDITION at its oss default"
  fi
}

# ── cluster selection ─────────────────────────────────────────────────────────────────
# Nothing here is tied to one cluster. By default it uses whatever kubectl context is
# current. KUBE_CONTEXT names one explicitly. EKS_CLUSTER is the convenience for the
# cloud case, where the context name is an ARN nobody types by hand.
#
# WHY THIS IS NOT JUST STRING BUILDING. `aws eks update-kubeconfig` writes an ARN-named
# context, but eksctl writes `<user>@<cluster>.<region>.eksctl.io`, so a cluster you
# created with eksctl has no ARN context and building one gives you
# `context "arn:aws:eks:..." does not exist` on the first kubectl call. Look for a
# context that actually points at this cluster before falling back to writing one.
resolve_ctx() {
  if [ -n "${KUBE_CONTEXT:-}" ]; then
    CTX="$KUBE_CONTEXT"; export CTX; return
  fi

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
      "jsonpath={range .contexts[?(@.context.cluster=='${cluster_entry}')]}{.name}{'\n'}{end}" 2>/dev/null \
      | head -1)"
    if [ -n "$found" ]; then CTX="$found"; export CTX; return; fi
  done

  log "no kubectl context for $EKS_CLUSTER; writing one with aws eks update-kubeconfig"
  aws eks update-kubeconfig --region "$region" --name "$EKS_CLUSTER" >/dev/null
  CTX="$arn"; export CTX
}

kc()   { kubectl --context "$CTX" "$@"; }
helm_() { helm --kube-context "$CTX" "$@"; }

# Apply a manifest with ${GATEWAY_CLASS} substituted, so one yaml/ dir serves both
# editions. envsubst is not assumed to be installed.
kc_apply_tmpl() {
  sed "s|\${GATEWAY_CLASS}|$GATEWAY_CLASS|g" "$1" | kc apply -f -
}
