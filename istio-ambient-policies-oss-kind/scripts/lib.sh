#!/usr/bin/env bash
# lib.sh: shared helpers for istio-ambient-policies-oss-kind.
#
# One kind cluster running UPSTREAM community Istio in ambient mode from the
# first helm install (no sidecar phase). Istio Bookinfo is deployed and
# enrolled by Flightbay's Deploy Bookinfo wizard, which also creates the
# namespace waypoint. Then four policies land on ratings one at a time, each
# with a probe that shows what changed:
#
#   1. PeerAuthentication STRICT       (ztunnel, L4)  the non-mesh caller is cut off from ratings
#   2. AuthorizationPolicy by identity (ztunnel, L4)  only reviews may connect: the waypoint gets refused
#   3. AuthorizationPolicy on waypoint (Envoy,   L7)  reviews may GET, nothing else
#   4. RequestAuthentication + JWT     (Envoy,   L7)  POST needs a valid token
#
# Edition: OSS. Istio images from docker.io/istio, upstream Helm charts,
# istioctl from the upstream GitHub release. No licence, no registry auth.

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

require() { command -v "$1" >/dev/null 2>&1 || die "$1 not found: install it first"; }

# show <cmd...>: print the command, then run it. The scripts narrate what they
# do so a reader (or an audience) sees real kubectl and helm, not wrapper names.
show() {
  local disp=("$@")
  case "${disp[0]}" in kc) disp[0]=kubectl ;; ic) disp[0]=istioctl ;; esac
  { printf '\n$ '; printf '%s ' "${disp[@]}"; printf '\n'; } >&2
  "$@"
}

# ── paths ─────────────────────────────────────────────────────────────────────
LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export LAB_ROOT
export LAB_BIN="$LAB_ROOT/.bin"          # istioctl is downloaded here (gitignored)
export PATH="$LAB_BIN:$PATH"

# ── cluster + namespace constants ─────────────────────────────────────────────
export CLUSTER_NAME="${CLUSTER_NAME:-ambient-policies-lab}"
export CTX="kind-${CLUSTER_NAME}"
export ISTIO_SYSTEM_NS="${ISTIO_SYSTEM_NS:-istio-system}"

# bookinfo : deployed and enrolled by Flightbay (Deploy Bookinfo). The callers
#            are reviews-v2 (sa bookinfo-reviews, the real ratings caller) and
#            demo-client (sa bookinfo-demo-client, Flightbay's traffic pod).
# legacy   : NOT in the mesh: a plain curl pod, the plaintext caller STRICT cuts off
export NS_APP="${NS_APP:-bookinfo}"
export NS_LEGACY="${NS_LEGACY:-legacy}"
export WAYPOINT_NAME="${WAYPOINT_NAME:-bookinfo-waypoint}"
export RATINGS_URL="${RATINGS_URL:-http://ratings.${NS_APP}:9080/ratings/0}"

# ── Istio: upstream OSS ───────────────────────────────────────────────────────
export ISTIO_VERSION="${ISTIO_VERSION:-1.30.6}"
export ISTIO_REGISTRY="${ISTIO_REGISTRY:-docker.io/istio}"
export ISTIO_HELM_REPO="${ISTIO_HELM_REPO:-https://istio-release.storage.googleapis.com/charts}"
export ISTIO_HELM_VERSION="${ISTIO_HELM_VERSION:-${ISTIO_VERSION}}"

case "$(uname -m)" in
  arm64|aarch64) export KIND_PLATFORM="${KIND_PLATFORM:-linux/arm64}"; ISTIOCTL_ARCH=arm64 ;;
  *)             export KIND_PLATFORM="${KIND_PLATFORM:-linux/amd64}"; ISTIOCTL_ARCH=amd64 ;;
esac
case "$(uname -s)" in
  Darwin) ISTIOCTL_OS=osx ;;
  *)      ISTIOCTL_OS=linux ;;
esac
export ISTIOCTL_OS ISTIOCTL_ARCH

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

check_docker() { docker info >/dev/null 2>&1 || die "docker daemon not reachable: start Docker Desktop / OrbStack"; }

# ── probes ────────────────────────────────────────────────────────────────────
# curl_code <namespace> <deployment> <method> [extra curl args...]
# HTTP status from inside a pod; "000" means the connection never completed
# (reset or refused), which is how an L4 deny looks to the caller.
curl_code() {
  local ns="$1" deploy="$2" method="$3"; shift 3
  kc -n "$ns" exec "deploy/$deploy" -- \
    curl -s -o /dev/null -w '%{http_code}' -X "$method" --max-time 5 "$@" "$RATINGS_URL" 2>/dev/null || true
}

# ztunnel pod on the node a given pod runs on (policy is enforced there)
ztunnel_for() { # <namespace> <pod-name>
  local node
  node="$(kc -n "$1" get pod "$2" -o jsonpath='{.spec.nodeName}')"
  kc -n "$ISTIO_SYSTEM_NS" get pod -l app=ztunnel \
    --field-selector "spec.nodeName=$node" -o jsonpath='{.items[0].metadata.name}'
}

# wait_code <want> <curl_code args...>: a policy takes a few seconds to reach
# ztunnel or the waypoint. Wait (up to 30s) until one probe shows it.
wait_code() {
  local want="$1"; shift
  local i
  for i in $(seq 1 15); do
    [[ "$(curl_code "$@")" == "$want" ]] && return 0
    sleep 2
  done
  warn "still not $want after 30s: $*"
}
