#!/usr/bin/env bash
# lib.sh — shared helpers for istio-ambient-cert-identity-kind.
#
# One kind cluster running the Solo distribution of Istio in AMBIENT mode,
# installed by the Gloo Operator. The lab is about workload identity at L4:
# every workload gets a SPIFFE SVID from its ServiceAccount, ztunnel enforces
# L4 AuthorizationPolicy on that identity with no waypoint, and we show the
# one thing SA-scoped identity cannot do — tell two pods that share a
# ServiceAccount apart — which is what the Solo 1.30 workload-claims feature
# (shown as reference) closes.
#
# Edition: ENTERPRISE. The mesh is installed and lifecycle-managed by the Gloo
# Operator (ServiceMeshController) on the Solo Istio images. Needs
# SOLO_ISTIO_LICENSE_KEY and gcloud auth to pull the images from
# us-docker.pkg.dev/soloio-img/istio.

set -Eeuo pipefail

# Central product/infra versions (generated from versions.json). Runtime env
# still wins; the := fallbacks keep the lab runnable if versions.env is absent.
__versions_env="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/versions.env"
[ -f "$__versions_env" ] && . "$__versions_env"
: "${SOLO_ISTIO_VERSION:=1.29.3-solo}"
: "${GLOO_OPERATOR_VERSION:=0.5.2}"
: "${GATEWAY_API_VERSION:=v1.5.1}"

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

# ── cluster + namespace constants ─────────────────────────────────────────────
# CLUSTER_NAME doubles as the mesh trust domain: the Gloo Operator sets
# trustDomain to the ServiceMeshController's .spec.cluster, so SPIFFE
# identities are spiffe://cert-identity/ns/<ns>/sa/<sa>, NOT cluster.local.
export CLUSTER_NAME="${CLUSTER_NAME:-cert-identity}"
export CTX="kind-${CLUSTER_NAME}"
export NS_APP="${NS_APP:-petshop}"

# ── Gloo Operator + Solo Istio ────────────────────────────────────────────────
export GLOO_SYSTEM_NS="${GLOO_SYSTEM_NS:-gloo-system}"
export ISTIO_SYSTEM_NS="${ISTIO_SYSTEM_NS:-istio-system}"
export OPERATOR_CHART="${OPERATOR_CHART:-oci://us-docker.pkg.dev/solo-public/gloo-operator-helm/gloo-operator}"
# The operator auto-appends "-solo" when distribution=Standard, so the SMC
# .spec.version takes the version WITHOUT the -solo suffix.
export ISTIO_VERSION="${ISTIO_VERSION:-${SOLO_ISTIO_VERSION%-solo}}"
export ISTIO_REGISTRY="${ISTIO_REGISTRY:-us-docker.pkg.dev/soloio-img/istio}"

case "$(uname -m)" in
  arm64|aarch64) export KIND_PLATFORM="${KIND_PLATFORM:-linux/arm64}" ;;
  *)             export KIND_PLATFORM="${KIND_PLATFORM:-linux/amd64}" ;;
esac

solo_istio_images() {
  echo "$ISTIO_REGISTRY/pilot:$ISTIO_VERSION"
  echo "$ISTIO_REGISTRY/proxyv2:$ISTIO_VERSION"
  echo "$ISTIO_REGISTRY/install-cni:$ISTIO_VERSION"
  echo "$ISTIO_REGISTRY/ztunnel:$ISTIO_VERSION"
}

# ── secrets loader ────────────────────────────────────────────────────────────
load_secrets() {
  if [[ -n "${SECRETS_FILE:-}" ]]; then
    [[ -f "$SECRETS_FILE" ]] || die "SECRETS_FILE='$SECRETS_FILE' does not exist"
    set -a; source "$SECRETS_FILE"; set +a
  fi
}
require_secrets() {
  load_secrets
  [[ -n "${SOLO_ISTIO_LICENSE_KEY:-}" ]] || \
    die "SOLO_ISTIO_LICENSE_KEY not set — export it or point SECRETS_FILE at a file that does"
}

# ── kubectl / istioctl helpers ────────────────────────────────────────────────
kc() { kubectl --context "$CTX" "$@"; }
ic() { istioctl --context "$CTX" "$@"; }

check_docker() { docker info >/dev/null 2>&1 || die "docker daemon not reachable — start Docker Desktop / OrbStack"; }
check_gcloud() { gcloud auth print-access-token >/dev/null 2>&1 || die "gcloud not authenticated — run 'gcloud auth login' (needed to pull Solo Istio images)"; }

kapply() { kc apply -f "$1" >/dev/null; }
