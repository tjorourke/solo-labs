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
: "${SOLO_ISTIO_VERSION:=1.29.3-solo}"     # proven multicluster-peering line
: "${GATEWAY_API_VERSION:=v1.4.0}"          # v1.5 VAP blocks bundled CRD installs

export REGION1="${REGION1:-eu-central-1}"
export REGION2="${REGION2:-eu-west-1}"
export NAME1="${NAME1:-mesh-eu-central}"
export NAME2="${NAME2:-mesh-eu-west}"
# eksctl writes contexts as <user>@<cluster>.<region>.eksctl.io — resolve dynamically
ctx_of() { kubectl config get-contexts -o name | grep "@${1}.${2}.eksctl.io" | head -1; }

export ISTIO_REGISTRY="us-docker.pkg.dev/soloio-img/istio"
export ISTIO_HELM_REPO="oci://us-docker.pkg.dev/soloio-img/istio-helm"
export ISTIO_HELM_VERSION="${SOLO_ISTIO_VERSION}"
export ISTIO_VERSION="${SOLO_ISTIO_VERSION%-solo}"   # 1.29 line: image tag drops -solo

log()    { echo "  $*"; }
ok()     { echo "  ✓ $*"; }
step()   { echo ""; echo "==> $*"; }
die()    { echo "ERROR: $*" >&2; exit 1; }

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
