#!/usr/bin/env bash
# lib.sh — shared helpers for agentgateway-egress-proxy-kind.
#
# Egress from agentgateway through a corporate forward proxy. Three shapes, all
# on real CRDs:
#   1. plain CONNECT tunnel (Squid), upstream TLS stays end to end
#   2. TLS-inspecting proxy (mitmproxy re-signs with a corporate CA), which is
#      where caCertificateRefs replaces insecureSkipVerify
#   3. proxy that demands Proxy-Authorization, and a proxy fronted by TLS
#
# Plus the air-gap case: a destination agentgateway cannot resolve at all, which
# the proxy resolves on its behalf.

set -Eeuo pipefail

# Central product/infra versions (generated from versions.json). Sourcing this
# lets a version bump in one place flow to every lab; runtime env still wins.
__versions_env="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/versions.env"
[ -f "$__versions_env" ] && . "$__versions_env"
: "${AGW_ENT_VERSION:=v2.3.4}"; : "${AGW_CALVER_VERSION:=v2026.8.2}"

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

# ── edition ───────────────────────────────────────────────────────────────────
# The tunnel and TLS fields are identical in both editions; only the apiVersion,
# the kind and the GatewayClass change. EDITION=oss runs the whole thing again
# on upstream agentgateway, in its own cluster on its own port, so both can be
# up at once.
export EDITION="${EDITION:-enterprise}"
if [[ "$EDITION" == "oss" ]]; then
  export CLUSTER_NAME="${CLUSTER_NAME:-egress-proxy-oss}"
  export GW_NODEPORT="${GW_NODEPORT:-30081}"
  export YAML_DIR="${YAML_DIR:-yaml-oss}"
  export GATEWAY_CLASS="${GATEWAY_CLASS:-agentgateway}"
  export BACKEND_GROUP="${BACKEND_GROUP:-agentgateway.dev}"
  export BACKEND_KIND="${BACKEND_KIND:-AgentgatewayBackend}"
else
  export CLUSTER_NAME="${CLUSTER_NAME:-egress-proxy}"
  export GW_NODEPORT="${GW_NODEPORT:-30080}"
  export YAML_DIR="${YAML_DIR:-yaml}"
  export GATEWAY_CLASS="${GATEWAY_CLASS:-enterprise-agentgateway}"
  export BACKEND_GROUP="${BACKEND_GROUP:-enterpriseagentgateway.solo.io}"
  export BACKEND_KIND="${BACKEND_KIND:-EnterpriseAgentgatewayBackend}"
fi
export CTX="kind-${CLUSTER_NAME}"

# Enterprise agentgateway, CalVer line. `spec.policies.tunnel` (backendRef | url,
# plus mode Auto|Connect) and `tls.caCertificateRefs[].kind: ConfigMap|Secret`
# are both present in the v2026.8.2 CRDs; the older SemVer 2.3.x backend has a
# narrower TLS block. Override AGW_VERSION to try another build.
export AGW_VERSION="${AGW_VERSION:-$AGW_CALVER_VERSION}"
export AGW_REGISTRY="${AGW_REGISTRY:-oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts}"
export AGW_GAR_HOST="${AGW_GAR_HOST:-us-docker.pkg.dev}"
export AGW_CHART="${AGW_CHART:-${AGW_REGISTRY}/enterprise-agentgateway}"
export AGW_CRDS_CHART="${AGW_CRDS_CHART:-${AGW_REGISTRY}/enterprise-agentgateway-crds}"
export GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.5.1}"

# Upstream agentgateway, for the OSS run. No license, no registry auth.
: "${AGW_OSS_VERSION:=v1.5.0}"
export AGW_OSS_REGISTRY="${AGW_OSS_REGISTRY:-oci://cr.agentgateway.dev/charts}"

export AGW_NS="${AGW_NS:-agentgateway-system}"
export UPSTREAM_NS="${UPSTREAM_NS:-upstream}"
export EGRESS_NS="${EGRESS_NS:-egress}"
export GATEWAY_NAME="${GATEWAY_NAME:-egress-gateway}"

# Pinned images for the supporting cast.
export SQUID_IMAGE="${SQUID_IMAGE:-ubuntu/squid:6.6-24.04_beta}"
export MITM_IMAGE="${MITM_IMAGE:-mitmproxy/mitmproxy:11.1.3}"
export NGINX_IMAGE="${NGINX_IMAGE:-nginx:1.27-alpine}"

# The destination the gateway is trying to reach. Two names, one certificate:
#  - API_HOST resolves in-cluster, so the direct (no proxy) baseline works.
#  - AIRGAP_HOST resolves nowhere. Only the proxy can reach it, which is the
#    air-gapped JWKS case.
export API_HOST="${API_HOST:-api.upstream.svc.cluster.local}"
export AIRGAP_HOST="${AIRGAP_HOST:-jwks.acme-external.internal}"

# Proxy credentials for the authenticating Squid.
export PROXY_USER="${PROXY_USER:-corpuser}"
export PROXY_PASS="${PROXY_PASS:-corppass}"

# Where generated keys and certificates land. Gitignored: regenerate, never commit.
export PKI_DIR="${PKI_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.pki}"

# ── secrets ───────────────────────────────────────────────────────────────────
load_secrets() {
  if [[ -n "${SECRETS_FILE:-}" ]]; then
    [[ -f "$SECRETS_FILE" ]] || die "SECRETS_FILE='$SECRETS_FILE' does not exist"
    set -a; source "$SECRETS_FILE"; set +a
  fi
}
require_secrets() {
  load_secrets
  if [[ -z "${AGENTGATEWAY_LICENSE_KEY:-}" ]]; then
    cat >&2 <<EOF

ERROR: missing AGENTGATEWAY_LICENSE_KEY (Solo Enterprise agentgateway license).

  export AGENTGATEWAY_LICENSE_KEY=...
  ./scripts/quick.sh up

  or:  SECRETS_FILE=/path/to/secrets.sh ./scripts/quick.sh up

  License: ask your Solo account team.
EOF
    exit 1
  fi
}

# ── kubectl + cluster helpers ─────────────────────────────────────────────────
kc() { kubectl --context "$CTX" "$@"; }

check_docker() { docker info >/dev/null 2>&1 || die "docker daemon not reachable — start Docker Desktop / OrbStack"; }

wait_deploy() {
  local ns="$1" name="$2" timeout="${3:-300s}"
  local end=$(( $(date +%s) + 180 ))
  until kc -n "$ns" get deployment "$name" >/dev/null 2>&1; do
    [[ $(date +%s) -ge $end ]] && { warn "deployment $ns/$name not created within 3m"; return 1; }
    sleep 3
  done
  kc -n "$ns" wait --for=condition=Available deployment/"$name" --timeout="$timeout" >/dev/null
}

# ensure_gar_auth — idempotent gcloud + docker + helm OCI auth for a Google
# Artifact Registry host. The Solo chart repo is public but helm OCI pull still
# returns 401 without a gcloud-token-backed `helm registry login`.
ensure_gar_auth() {
  local host="$1"
  command -v gcloud >/dev/null 2>&1 || die "gcloud required for the Solo chart at $host. Install: brew install --cask google-cloud-sdk; gcloud auth login"
  if ! gcloud auth print-access-token >/dev/null 2>&1; then
    [[ -t 0 ]] || die "gcloud not authenticated and no TTY. Run: gcloud auth login"
    gcloud auth login || die "gcloud auth login failed"
  fi
  if ! grep -q "\"${host}\":" "$HOME/.docker/config.json" 2>/dev/null; then
    log "configuring docker credential helper for $host"
    gcloud auth configure-docker --quiet "$host" >/dev/null
  fi
  log "helm registry login → $host"
  gcloud auth print-access-token \
    | helm registry login -u oauth2accesstoken --password-stdin "$host" >/dev/null \
    || die "helm registry login failed for $host (on macOS click 'Always Allow' on the Keychain prompt, then re-run)"
}

# helm_install_with_progress — helm upgrade --install --wait with periodic pod
# snapshots so a cold-pull install does not look hung.
helm_install_with_progress() {
  local release="$1" chart="$2" namespace="$3"; shift 3
  helm --kube-context "$CTX" upgrade --install "$release" "$chart" \
    --namespace "$namespace" --create-namespace "$@" >/dev/null &
  local pid=$!; local start; start=$(date +%s)
  while kill -0 "$pid" 2>/dev/null; do
    sleep 15; kill -0 "$pid" 2>/dev/null || break
    local e=$(( $(date +%s) - start ))
    local p; p=$(kc -n "$namespace" get pods --no-headers 2>/dev/null | awk '{printf "%s[%s] ", $1, $2}')
    [[ -n "$p" ]] && log "[+${e}s] pods: ${p}" || log "[+${e}s] pulling images / creating pods..."
  done
  wait "$pid"
}

# gateway_service — name of the Service the AGW deployer created for our Gateway.
gateway_service() {
  kc -n "$AGW_NS" get svc -l "gateway.networking.k8s.io/gateway-name=${GATEWAY_NAME}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# The Gateway Service is pinned to a NodePort the kind config maps to the host,
# so the tests curl a stable URL with no port-forward to babysit. GW_NODEPORT is
# set per edition above.
export GW_URL="${GW_URL:-http://localhost:${GW_NODEPORT}}"
