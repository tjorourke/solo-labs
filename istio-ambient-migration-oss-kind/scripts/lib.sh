#!/usr/bin/env bash
# lib.sh — shared helpers for istio-ambient-migration-oss-kind.
#
# One kind cluster running UPSTREAM community Istio, migrated from sidecar mode
# to ambient namespace by namespace. The mesh-level switch is a helm upgrade
# (istiod profile=ambient + the cni and ztunnel charts); the per-namespace
# switch is one label. Every L7 namespace shares a SINGLE cluster-wide waypoint
# (a Gateway in mesh-infra with allowedRoutes: All), the L4-only namespace
# migrates with no waypoint at all, and one namespace rolls back to sidecars at
# the end to prove the switch works in both directions.
#
# Edition: OSS ONLY. Istio images from docker.io/istio, upstream Helm charts.
# No licence, no registry auth, no enterprise images, no enterprise CRDs.

set -Eeuo pipefail

__versions_env="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/versions.env"
[ -f "$__versions_env" ] && . "$__versions_env"
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
export CLUSTER_NAME="${CLUSTER_NAME:-ambient-oss}"
export CTX="kind-${CLUSTER_NAME}"
export ISTIO_SYSTEM_NS="${ISTIO_SYSTEM_NS:-istio-system}"

# App namespaces (all start in sidecar mode):
#   petstore         — L7: catalog v1/v2 canary + HTTP GET-only authz. Migrates
#                      behind the shared waypoint.
#   petstore-orders  — L7: the SECOND namespace on the SAME waypoint (the point
#                      of a cluster-wide waypoint), and the one we roll back.
#   petstore-data    — L4-only: redis, STRICT mTLS + identity authz. Migrates
#                      with NO waypoint (ztunnel does it all).
#   petstore-clients — fortio + checkout, the calling estate. Migrates so the
#                      waypoint's L7 policy applies to its calls.
export NS_APP="${NS_APP:-petstore}"
export NS_ORDERS="${NS_ORDERS:-petstore-orders}"
export NS_DATA="${NS_DATA:-petstore-data}"
export NS_CLIENTS="${NS_CLIENTS:-petstore-clients}"

# The ONE waypoint for the whole cluster lives here.
export NS_WAYPOINT="${NS_WAYPOINT:-mesh-infra}"
export WAYPOINT_NAME="${WAYPOINT_NAME:-cluster-waypoint}"

# ── Istio: upstream OSS ───────────────────────────────────────────────────────
export ISTIO_VERSION="${ISTIO_VERSION:-1.30.3}"
export ISTIO_REGISTRY="${ISTIO_REGISTRY:-docker.io/istio}"
export ISTIO_HELM_REPO="${ISTIO_HELM_REPO:-https://istio-release.storage.googleapis.com/charts}"
export ISTIO_HELM_VERSION="${ISTIO_HELM_VERSION:-${ISTIO_VERSION}}"

case "$(uname -m)" in
  arm64|aarch64) export KIND_PLATFORM="${KIND_PLATFORM:-linux/arm64}" ;;
  *)             export KIND_PLATFORM="${KIND_PLATFORM:-linux/amd64}" ;;
esac

istio_images() {
  echo "$ISTIO_REGISTRY/pilot:$ISTIO_VERSION"
  echo "$ISTIO_REGISTRY/proxyv2:$ISTIO_VERSION"
  echo "$ISTIO_REGISTRY/install-cni:$ISTIO_VERSION"
  echo "$ISTIO_REGISTRY/ztunnel:$ISTIO_VERSION"
}

# helm chart ref: OCI repos take "$REPO/chart", classic repos take "chart --repo $REPO"
helm_chart() { # helm_chart <name> -> prints args
  if [[ "$ISTIO_HELM_REPO" == oci://* ]]; then
    printf '%s/%s' "$ISTIO_HELM_REPO" "$1"
  else
    printf '%s --repo %s' "$1" "$ISTIO_HELM_REPO"
  fi
}

# ── kubectl / istioctl helpers ────────────────────────────────────────────────
kc() { kubectl --context "$CTX" "$@"; }
ic() { istioctl --context "$CTX" "$@"; }
kapply() { kc apply -f "$1" >/dev/null; }

check_docker() { docker info >/dev/null 2>&1 || die "docker daemon not reachable — start Docker Desktop / OrbStack"; }
