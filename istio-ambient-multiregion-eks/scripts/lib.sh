#!/usr/bin/env bash
# lib.sh — shared helpers for istio-ambient-multiregion-eks.
#
# Two EKS clusters in two AWS regions, peered into one ambient mesh
# (istiod-to-istiod, east-west gateways on internet-facing NLBs, shared root
# CA). Three demos for the multi-region PoC questions:
#   04 — pod failover: local endpoints die -> global service serves cross-region
#   05 — region failover: kgateway ingress per region + Global Accelerator
#   06 — scale ramp: N tenants as global services, istiod/ztunnel metrics
#
# AWS auth comes from the environment (aws sts get-caller-identity must work).
# Never hardcode account ids / profiles here.

set -Eeuo pipefail

__versions_env="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/versions.env"
[ -f "$__versions_env" ] && . "$__versions_env"
: "${SOLO_ISTIO_VERSION:=1.30.4-solo}"     # proven multicluster-peering line (versions.env normally wins)
: "${GATEWAY_API_VERSION:=v1.4.0}"          # v1.5 VAP blocks bundled CRD installs

export REGION1="${REGION1:-eu-central-1}"
export REGION2="${REGION2:-eu-west-1}"
export NAME1="${NAME1:-mesh-eu-central}"
export NAME2="${NAME2:-mesh-eu-west}"
# eksctl writes contexts as <user>@<cluster>.<region>.eksctl.io — resolve dynamically
# `|| true` so a MISSING context returns empty instead of killing the script.
# Without it the grep exits 1, set -e ends the run inside the command
# substitution, and the caller's `die "no kube context for ..."` never prints, so
# the failure looks like the step produced no output at all.
ctx_of() { kubectl config get-contexts -o name 2>/dev/null | grep "@${1}.${2}.eksctl.io" | head -1 || true; }

export ISTIO_REGISTRY="us-docker.pkg.dev/soloio-img/istio"
export ISTIO_HELM_REPO="oci://us-docker.pkg.dev/soloio-img/istio-helm"
export ISTIO_HELM_VERSION="${SOLO_ISTIO_VERSION}"
# KEEP the -solo suffix on the image tag. This is the Solo distribution of Istio
# and the suffix is what selects it; the bare tag (1.30.x) in the same registry
# is the community build. Getting this wrong is silent and expensive: community
# istiod peers only via remote secrets, has no Enterprise multicluster licence
# check and never publishes <svc>.<ns>.mesh.internal global services, so the
# mesh looks healthy (Peers Check even goes green) while every global-service
# demo in this lab quietly does nothing. The 1.29 line dropped the suffix, which
# is where this drifted in from.
export ISTIO_VERSION="${SOLO_ISTIO_VERSION}"

log()    { echo "  $*"; }
ok()     { echo "  ✓ $*"; }
step()   { echo ""; echo "==> $*"; }
die()    { echo "ERROR: $*" >&2; exit 1; }
# warn was used by teardown.sh but never defined anywhere. Under `set -e` an
# undefined command exits 127, so the one path that called it (load balancers
# still present after 10 minutes) killed the teardown immediately BEFORE the
# cluster delete, leaving both clusters billing.
warn()   { echo "WARN: $*" >&2; }

load_secrets() {
  if [[ -n "${SECRETS_FILE:-}" ]]; then
    [[ -f "$SECRETS_FILE" ]] || die "SECRETS_FILE='$SECRETS_FILE' does not exist"
    set -a; source "$SECRETS_FILE"; set +a
  fi
}
require_license() {
  load_secrets
  [[ -n "${SOLO_ISTIO_LICENSE_KEY:-}" ]] || die "SOLO_ISTIO_LICENSE_KEY not set"
}
require_aws() {
  # This lab creates paid infrastructure — force an explicit, conscious profile
  # choice. LAB_AWS_PROFILE wins over anything a sourced secrets file exported.
  [[ -n "${LAB_AWS_PROFILE:-}" ]] || die "set LAB_AWS_PROFILE=<aws profile for this lab> (it overrides any AWS_PROFILE from secrets files)"
  export AWS_PROFILE="$LAB_AWS_PROFILE"
  aws sts get-caller-identity >/dev/null 2>&1 || die "AWS credentials not working for profile '$AWS_PROFILE' (try: aws sso login --profile $AWS_PROFILE)"
  log "AWS profile: $AWS_PROFILE"
}

# `istioctl multicluster check` is version-sensitive: a client from an older
# line can report a healthy peered mesh as broken. Use the host binary only when
# it matches SOLO_ISTIO_VERSION exactly, otherwise fetch the matching Solo build
# into the lab's own (gitignored) state dir. Sets $ISTIOCTL.
require_istioctl() {
  local lab_root want="$SOLO_ISTIO_VERSION" have=""
  lab_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  if command -v istioctl >/dev/null 2>&1; then
    have="$(istioctl version --remote=false 2>/dev/null | awk '{print $NF}')"
  fi
  if [[ "$have" == "$want" ]]; then
    ISTIOCTL="$(command -v istioctl)"; export ISTIOCTL
    log "istioctl $have (host binary matches $want)"
    return
  fi
  ISTIOCTL="$lab_root/.state/bin/istioctl"
  if [[ ! -x "$ISTIOCTL" ]] || [[ "$("$ISTIOCTL" version --remote=false 2>/dev/null | awk '{print $NF}')" != "$want" ]]; then
    local os arch; os="$(uname -s | tr '[:upper:]' '[:lower:]')"; arch="$(uname -m)"
    [[ "$os" == "darwin" ]] && os="osx"
    case "$arch" in x86_64) arch=amd64;; aarch64) arch=arm64;; esac
    step "Downloading Solo istioctl $want ($os-$arch) — host has '${have:-none}'"
    mkdir -p "$lab_root/.state/bin"
    curl -sSfL "https://storage.googleapis.com/soloio-istio-binaries/release/${want}/istio-${want}-${os}-${arch}.tar.gz" \
      | tar xz -C "$lab_root/.state" "istio-${want}/bin/istioctl" \
      || die "could not download istioctl $want"
    mv "$lab_root/.state/istio-${want}/bin/istioctl" "$ISTIOCTL"
    rm -rf "$lab_root/.state/istio-${want}"
  fi
  export ISTIOCTL
  ok "istioctl $("$ISTIOCTL" version --remote=false 2>/dev/null) at .state/bin/istioctl"
}
