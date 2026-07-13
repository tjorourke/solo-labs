#!/usr/bin/env bash
# lib.sh — shared helpers for istio-ambient-migration-kind.
#
# One kind cluster running the Solo distribution of Istio, installed and driven
# by the Gloo Operator (a single ServiceMeshController CR). The lab starts in
# sidecar mode, flips the whole mesh to ambient with one field, then migrates a
# petstore app namespace by namespace — L4 first (ztunnel only), then L7 (behind
# a waypoint) — keeping DestinationRule + VirtualService routing working the
# whole way, and proving zero downtime with a fortio load generator that runs
# across every cut. It finishes with the Solo-only capability that makes a mixed
# sidecar/ambient fleet safe: sidecar and ingress traffic routed through a
# waypoint so its L7 policy is enforced for callers that still have a sidecar.
#
# Edition: ENTERPRISE ONLY. The headline — a sidecar or the ingress gateway
# sending traffic through an ambient waypoint (istio.io/use-waypoint /
# istio.io/ingress-use-waypoint) — is a Solo-distribution behaviour with no
# community-Istio equivalent, so the migration is only safe across a mixed fleet
# on the Solo images. Needs SOLO_ISTIO_LICENSE_KEY and gcloud auth to pull the
# Solo images from us-docker.pkg.dev/soloio-img/istio.

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

# ── cluster + namespace constants ───────────────────────────────────────────────
export CLUSTER_NAME="${CLUSTER_NAME:-ambient-migration}"
export CTX="kind-${CLUSTER_NAME}"

# Petstore namespaces:
#   petstore        — the L7 namespace: catalog v1/v2 subsets (DR+VS canary),
#                     HTTP AuthorizationPolicy, VS retries/timeout. Needs a waypoint.
#   petstore-data   — L4-only: a TCP data store. STRICT mTLS + L4 authz. NO waypoint.
#   petstore-legacy — a client we deliberately leave on sidecars during the
#                     Solo sidecar→waypoint demo (the "mixed fleet" caller).
export NS_APP="${NS_APP:-petstore}"
export NS_DATA="${NS_DATA:-petstore-data}"
export NS_LEGACY="${NS_LEGACY:-petstore-legacy}"
export NS_INGRESS="${NS_INGRESS:-istio-ingress}"

# ── Gloo Operator + Solo Istio ──────────────────────────────────────────────────
export GLOO_SYSTEM_NS="${GLOO_SYSTEM_NS:-gloo-system}"
export ISTIO_SYSTEM_NS="${ISTIO_SYSTEM_NS:-istio-system}"
export OPERATOR_CHART="${OPERATOR_CHART:-oci://us-docker.pkg.dev/solo-public/gloo-operator-helm/gloo-operator}"
# The operator auto-appends "-solo" when distribution=Standard, so the SMC
# .spec.version takes the version WITHOUT the -solo suffix.
export ISTIO_VERSION="${ISTIO_VERSION:-${SOLO_ISTIO_VERSION%-solo}}"
export ISTIO_REGISTRY="${ISTIO_REGISTRY:-us-docker.pkg.dev/soloio-img/istio}"

# Node platform for single-platform image saves (kind nodes run the host arch).
case "$(uname -m)" in
  arm64|aarch64) export KIND_PLATFORM="${KIND_PLATFORM:-linux/arm64}" ;;
  *)             export KIND_PLATFORM="${KIND_PLATFORM:-linux/amd64}" ;;
esac

# Solo Istio images pre-pulled on the host (which has gcloud creds) and loaded
# into kind, so the cluster needs no in-cluster pull secret.
solo_istio_images() {
  echo "$ISTIO_REGISTRY/pilot:$ISTIO_VERSION"
  echo "$ISTIO_REGISTRY/proxyv2:$ISTIO_VERSION"
  echo "$ISTIO_REGISTRY/install-cni:$ISTIO_VERSION"
  echo "$ISTIO_REGISTRY/ztunnel:$ISTIO_VERSION"
}

# ── secrets loader ──────────────────────────────────────────────────────────────
# Enterprise needs SOLO_ISTIO_LICENSE_KEY. Point SECRETS_FILE at a sourceable
# shell file, or export SOLO_ISTIO_LICENSE_KEY directly.
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

# ── kubectl / istioctl helpers ───────────────────────────────────────────────────
kc() { kubectl --context "$CTX" "$@"; }
ic() { istioctl --context "$CTX" "$@"; }

check_docker() {
  docker info >/dev/null 2>&1 || die "docker daemon not reachable — start Docker Desktop / OrbStack"
}

check_gcloud() {
  gcloud auth print-access-token >/dev/null 2>&1 || \
    die "gcloud not authenticated — run 'gcloud auth login' (needed to pull Solo Istio images)"
}

wait_deploy() {
  local ns="$1" name="$2" timeout="${3:-180s}"
  local end=$(( $(date +%s) + 180 ))
  until kc -n "$ns" get deployment "$name" >/dev/null 2>&1; do
    [[ $(date +%s) -ge $end ]] && { warn "deployment $ns/$name not created within 3m"; return 1; }
    sleep 3
  done
  kc -n "$ns" wait --for=condition=Available deployment/"$name" --timeout="$timeout" >/dev/null
}

# Apply a manifest dir/file against the lab context.
kapply() { kc apply -f "$1" >/dev/null; }
