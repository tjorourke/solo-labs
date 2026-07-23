#!/usr/bin/env bash
# lib.sh — shared helpers for istio-ambient-demo-kind.
#
# TWO kind clusters (mesh1 + mesh2) running the Solo distribution of Istio in
# AMBIENT mode, installed from the Helm charts (no operator), peered into one
# mesh with `istioctl multicluster expose` + `link`. The lab is a two-part
# customer demo driven from demo.ipynb:
#   Part 1 — multicluster: bookinfo on both clusters, global services
#            (*.mesh.internal), cross-cluster failover, L7 waypoint.
#   Part 2 — cert identity: the petshop L4/L7 identity story on mesh1 only.
#
# Edition: ENTERPRISE. Needs SOLO_ISTIO_LICENSE_KEY + AGENTGATEWAY_LICENSE_KEY
# and gcloud auth to pull images from us-docker.pkg.dev/soloio-img/istio.

set -Eeuo pipefail

# Pin the Solo 1.30 line BEFORE sourcing the repo-wide versions.env (whose
# ${VAR:-default} keeps whatever is already set). Part 2's workload-claims step
# needs 1.30.3-solo. A runtime SOLO_ISTIO_VERSION env still wins.
: "${SOLO_ISTIO_VERSION:=1.30.3-solo}"
__versions_env="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/versions.env"
[ -f "$__versions_env" ] && . "$__versions_env"
: "${GATEWAY_API_VERSION:=v1.5.1}"
: "${METALLB_VERSION:=v0.14.9}"

# ── logging ───────────────────────────────────────────────────────────────────
log()  { echo "  $*" >&2; }
ok()   { echo "  ✓ $*" >&2; }
warn() { echo "  ! $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }
step() { { echo ""; echo "══> $*"; } >&2; }
require() { command -v "$1" >/dev/null 2>&1 || die "$1 not found — install it first"; }

# ── clusters ──────────────────────────────────────────────────────────────────
export CLUSTER1_NAME="${CLUSTER1_NAME:-mesh1}"
export CLUSTER2_NAME="${CLUSTER2_NAME:-mesh2}"
export CLUSTER1="kind-${CLUSTER1_NAME}"
export CLUSTER2="kind-${CLUSTER2_NAME}"

# ── Solo Istio via Helm charts (no Gloo Operator) ─────────────────────────────
export ISTIO_SYSTEM_NS="${ISTIO_SYSTEM_NS:-istio-system}"
# On the 1.30 line the image tag KEEPS the -solo suffix (pilot:1.30.3-solo) —
# the plain 1.30.x tag in the same registry is the upstream build with none of
# the Solo additions (multicluster + workload claims silently missing).
export ISTIO_REGISTRY="${ISTIO_REGISTRY:-us-docker.pkg.dev/soloio-img/istio}"
export ISTIO_VERSION="${ISTIO_VERSION:-${SOLO_ISTIO_VERSION}}"
export ISTIO_HELM_REPO="${ISTIO_HELM_REPO:-oci://us-docker.pkg.dev/soloio-img/istio-helm}"
export ISTIO_HELM_VERSION="${ISTIO_HELM_VERSION:-${SOLO_ISTIO_VERSION}}"

# Solo Enterprise for agentgateway — ingress (Part 1) and the L7 waypoint
# data plane (Part 1 §8 + Part 2 §10 onwards).
export AGW_VERSION="${AGW_VERSION:-v2026.7.0}"
export AGW_CHARTS="${AGW_CHARTS:-oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts}"

# Gloo Platform (the Solo UI / Gloo UI): mgmt plane on mesh1, agent on both, so
# the service graph spans both clusters. 2.13.x pairs with Istio 1.30.
export GLOO_PLATFORM_VERSION="${GLOO_PLATFORM_VERSION:-2.13.2}"
export GLOO_MESH_NS="${GLOO_MESH_NS:-gloo-mesh}"

# The Solo istioctl build (has the `multicluster expose|link|check` commands).
# setup.sh downloads the matching version here if not already present.
export ISTIOCTL_BIN_DIR="${ISTIOCTL_BIN_DIR:-$HOME/.istioctl/bin}"
export ISTIOCTL="${ISTIOCTL:-$ISTIOCTL_BIN_DIR/istioctl-${SOLO_ISTIO_VERSION}}"

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
  [[ -n "${AGENTGATEWAY_LICENSE_KEY:-}" ]] || \
    die "AGENTGATEWAY_LICENSE_KEY not set — export it or point SECRETS_FILE at a file that does"
}

check_docker() { docker info >/dev/null 2>&1 || die "docker daemon not reachable — start Docker Desktop / OrbStack"; }
check_gcloud() { gcloud auth print-access-token >/dev/null 2>&1 || die "gcloud not authenticated — run 'gcloud auth login' (needed to pull Solo Istio images)"; }
