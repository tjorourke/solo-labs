#!/usr/bin/env bash
# lib.sh — shared helpers for istio-ambient-istio-csr-kind.
#
# One kind cluster where the mesh CA is HashiCorp Vault behind cert-manager
# istio-csr, and the whole PKI starts life as RSA — root, intermediate, and a
# Vault PKI role locked to key_type=rsa, the way an estate that standardised on
# RSA years ago would run it. Sidecars are happy: istio-agent generates RSA-2048
# workload keys by default. Then ambient arrives: ztunnel hardcodes ECDSA P-256
# for its workload CSRs (there is no RSA option in ztunnel), so the RSA-only
# Vault role rejects every ztunnel CSR with "role requires keys of type rsa".
# The lab proves the safe way through: flip the role to key_type=any (key type
# is chosen client-side — sidecars keep sending RSA, ztunnel sends EC), migrate
# one namespace to ambient, and leave the other on sidecars untouched.
#
# Edition: OSS ONLY. Everything here is upstream — Istio images from
# docker.io/istio, upstream Helm charts, upstream cert-manager, istio-csr and
# Vault. No licence, no enterprise images, no enterprise CRDs.

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
export CLUSTER_NAME="${CLUSTER_NAME:-istio-csr}"
export CTX="kind-${CLUSTER_NAME}"
export ISTIO_SYSTEM_NS="${ISTIO_SYSTEM_NS:-istio-system}"
export VAULT_NS="${VAULT_NS:-vault}"
export CM_NS="${CM_NS:-cert-manager}"
# The two app namespaces the whole lab is about:
#   ledger    — stays on sidecars (RSA workload certs) for the entire lab
#   payments  — migrates to ambient (EC workload certs)
# plus preflight — a scratch namespace enrolled into ambient FIRST, so the
# RSA-only Vault role rejects ztunnel where no real workload can be hurt.
export NS_STAY="${NS_STAY:-ledger}"
export NS_MOVE="${NS_MOVE:-payments}"
export NS_PRE="${NS_PRE:-preflight}"

# ── component versions ────────────────────────────────────────────────────────
export CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.21.1}"
# istio-csr ≥ v0.12.0 is required for ambient (trusted CA node accounts, the
# mechanism that lets ztunnel authenticate as itself and request certs for the
# workload identities it impersonates).
export ISTIO_CSR_VERSION="${ISTIO_CSR_VERSION:-v0.16.0}"
export VAULT_CHART_VERSION="${VAULT_CHART_VERSION:-0.34.0}"

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

# ── kubectl / istioctl / vault helpers ────────────────────────────────────────
kc() { kubectl --context "$CTX" "$@"; }
ic() { istioctl --context "$CTX" "$@"; }
kapply() { kc apply -f "$1" >/dev/null; }

check_docker() { docker info >/dev/null 2>&1 || die "docker daemon not reachable — start Docker Desktop / OrbStack"; }

# Run a vault CLI command inside the vault-0 pod (dev mode, root token).
# No local vault CLI needed.
vexec() {
  kc -n "$VAULT_NS" exec -i vault-0 -- \
    env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root vault "$@"
}

# ── certificate inspection helpers ────────────────────────────────────────────
# Leaf cert PEM of a SIDECAR workload, from Envoy's SDS state.
sidecar_leaf_pem() { # <ns> <deploy>
  ic proxy-config secret "deploy/$2" -n "$1" -o json 2>/dev/null \
    | jq -r '.dynamicActiveSecrets[] | select(.name=="default")
             | .secret.tlsCertificate.certificateChain.inlineBytes' \
    | base64 -d
}
# Leaf cert PEM of an AMBIENT workload, from the ztunnel on the pod's node.
ztunnel_leaf_pem() { # <ns> <sa>
  local pod node zt
  pod="$(kc -n "$1" get pods -o jsonpath='{.items[0].metadata.name}')"
  node="$(kc -n "$1" get pod "$pod" -o jsonpath='{.spec.nodeName}')"
  zt="$(kc -n "$ISTIO_SYSTEM_NS" get pods -l app=ztunnel \
        --field-selector "spec.nodeName=${node}" -o jsonpath='{.items[0].metadata.name}')"
  ic ztunnel-config certificate "$zt.$ISTIO_SYSTEM_NS" -o json 2>/dev/null \
    | jq -r --arg id "/ns/$1/sa/$2" \
        '.[] | select(.identity | endswith($id)) | .certChain[0].pem' \
    | base64 -d 2>/dev/null || \
  ic ztunnel-config certificate "$zt.$ISTIO_SYSTEM_NS" -o json 2>/dev/null \
    | jq -r --arg id "/ns/$1/sa/$2" \
        '.[] | select(.identity | endswith($id)) | .certChain[0].pem'
}
# "rsaEncryption" or "id-ecPublicKey" from a PEM on stdin.
pem_key_algo() { openssl x509 -noout -text 2>/dev/null | awk -F': ' '/Public Key Algorithm/{print $2; exit}'; }
pem_serial()   { openssl x509 -noout -serial 2>/dev/null | cut -d= -f2; }
pem_issuer()   { openssl x509 -noout -issuer 2>/dev/null; }
