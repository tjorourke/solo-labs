#!/usr/bin/env bash
# peer-with.sh — Consume a peer bundle from the OTHER machine and finish the
# peering on this side. Pairs with `expose-ew-on-host.sh` on the peer (which
# republishes that machine's east-west GW on its LAN IP).
#
# What this does on the LOCAL cluster:
#   1. Extracts the peer bundle (root-ca.{crt,key}, cluster-name.txt,
#      eastwest-ip.txt). Note what is NOT in it: any credential for the peer.
#   2. Verifies the local cacerts secret was signed by the same root CA the bundle
#      ships. (If not, the peering will silently fail mTLS — better to bail now.)
#   3. Points the local cluster at the peer's east-west gateway, either as a
#      `remote.items[]` entry on the peering helm release or as an istio-remote
#      Gateway CR. That one address serves both halves: :15008 for HBONE data
#      plane and :15012 for the istiod-to-istiod xDS connection the two control
#      planes federate over. No kubeconfig, and no access to the peer's
#      Kubernetes API.
#
# Usage:
#   ./scripts/peer-with.sh <local-cluster-name> <path/to/peer-bundle.tar.gz> <peer-ew-host:port>
#
# Example (peer is on 192.168.1.42, peer ran expose-ew-on-host.sh, which gave
# 192.168.1.42:15008 as the HBONE endpoint):
#   ./scripts/peer-with.sh green /tmp/peer-bundle-blue.tar.gz 192.168.1.42:15008
#
# Env overrides:
#   PEER_XDS_OFFSET    — XDS port offset from HBONE (default 4 → 15012 for 15008).
#   SOLO_ISTIO_VERSION — helm chart version (default 1.29.2-solo).

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SOLO_ISTIO_VERSION="${SOLO_ISTIO_VERSION:-1.29.2-solo}"
PEERING_CHART="${PEERING_CHART:-oci://us-docker.pkg.dev/soloio-img/istio-helm/peering}"
PEER_XDS_OFFSET="${PEER_XDS_OFFSET:-4}"
CERTS_DIR="$REPO_ROOT/certs"

# ── Utilities ─────────────────────────────────────────────────────────────────

log()    { echo "  $*"; }
log_ok() { echo "  ✓ $*"; }
step()   { echo ""; echo "══> $*"; }
die()    { echo "ERROR: $*" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || die "$1 not found — install it first"; }

YEL=$'\033[33m'
RST=$'\033[0m'

validate_name() {
  local n="$1"
  [[ -n "$n" ]] || die "cluster name required."
  [[ "$n" =~ ^[a-z][a-z0-9-]*[a-z0-9]$ ]] || die "'$n' is not a valid k8s DNS label"
}

# ── Args ──────────────────────────────────────────────────────────────────────

LOCAL_NAME="${1:-}"
BUNDLE_PATH="${2:-}"
PEER_EW_ENDPOINT="${3:-}"

validate_name "$LOCAL_NAME"
[[ -n "$BUNDLE_PATH" && -f "$BUNDLE_PATH" ]] || die "peer bundle not found: '$BUNDLE_PATH'"
[[ -n "$PEER_EW_ENDPOINT" ]] || die "peer east-west endpoint required (e.g. 192.168.1.42:15008)"
[[ "$PEER_EW_ENDPOINT" == *:* ]] || die "peer endpoint must be host:port (got '$PEER_EW_ENDPOINT')"

LOCAL_CTX="kind-${LOCAL_NAME}"
PEER_HOST="${PEER_EW_ENDPOINT%:*}"
PEER_HBONE_PORT="${PEER_EW_ENDPOINT##*:}"
PEER_XDS_PORT=$(( PEER_HBONE_PORT + PEER_XDS_OFFSET ))

# ── Prereqs ───────────────────────────────────────────────────────────────────

step "Checking prereqs"
require tar; require kubectl; require helm; require openssl
log_ok "tools present"

kubectl --context "$LOCAL_CTX" get ns istio-system >/dev/null 2>&1 \
  || die "kube context '$LOCAL_CTX' or namespace istio-system not reachable"
log_ok "kube context $LOCAL_CTX reachable"

# ── Extract bundle ────────────────────────────────────────────────────────────

step "Extracting peer bundle"
TMP_DIR="$(mktemp -d -t solo-peer-bundle.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT
tar -xzf "$BUNDLE_PATH" -C "$TMP_DIR"

# Bundle should contain exactly one directory: peer-bundle-<peer-name>.
BUNDLE_INNER="$(find "$TMP_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)"
[[ -n "$BUNDLE_INNER" && -d "$BUNDLE_INNER" ]] || die "bundle layout unexpected — no inner peer-bundle-* dir"

PEER_NAME="$(cat "$BUNDLE_INNER/cluster-name.txt" 2>/dev/null || true)"
[[ -n "$PEER_NAME" ]] || die "bundle missing cluster-name.txt"
validate_name "$PEER_NAME"

[[ -f "$BUNDLE_INNER/root-ca.crt" ]] || die "bundle missing root-ca.crt"
[[ -f "$BUNDLE_INNER/root-ca.key" ]] || die "bundle missing root-ca.key"
[[ -f "$BUNDLE_INNER/eastwest-ip.txt" ]] || die "bundle missing eastwest-ip.txt"

PEER_EW_BRIDGE_IP="$(cat "$BUNDLE_INNER/eastwest-ip.txt")"
log_ok "bundle peer cluster: $PEER_NAME  (bridge-IP $PEER_EW_BRIDGE_IP)"

# ── Verify root CA matches ────────────────────────────────────────────────────

step "Verifying local cacerts chains to the bundle's root CA"
BUNDLE_ROOT_SHA="$(openssl x509 -in "$BUNDLE_INNER/root-ca.crt" -noout -fingerprint -sha256 \
  | sed 's/.*=//; s/://g' | tr 'A-F' 'a-f')"

LOCAL_ROOT_PEM="$(kubectl --context "$LOCAL_CTX" -n istio-system get secret cacerts \
  -o jsonpath='{.data.root-cert\.pem}' 2>/dev/null | base64 -d 2>/dev/null || true)"
[[ -n "$LOCAL_ROOT_PEM" ]] || die "local cluster has no istio-system/cacerts secret — has quick-single.sh run?"

LOCAL_ROOT_SHA="$(echo "$LOCAL_ROOT_PEM" | openssl x509 -noout -fingerprint -sha256 \
  | sed 's/.*=//; s/://g' | tr 'A-F' 'a-f')"

if [[ "$BUNDLE_ROOT_SHA" != "$LOCAL_ROOT_SHA" ]]; then
  cat >&2 <<EOF

ERROR: root CA mismatch — peering will fail mTLS.

  Local  root-ca SHA256: $LOCAL_ROOT_SHA
  Bundle root-ca SHA256: $BUNDLE_ROOT_SHA

  The two clusters' intermediate CAs MUST chain back to the same root.
  Fix: tear this cluster down, drop the bundle's root-ca.{crt,key} into
  certs/ on this machine, then re-run quick-single.sh $LOCAL_NAME so the
  intermediate is regenerated from the shared root.

EOF
  exit 1
fi
log_ok "root CA matches (sha256 $LOCAL_ROOT_SHA)"

# ── No remote secret, deliberately ────────────────────────────────────────────
# Peering in the Solo distribution is a decentralised, push-based model: the
# local istiod opens an mTLS xDS connection to the peer's east-west gateway on
# :15012 and the two control planes exchange federated service and workload
# information over it. So there is nothing to apply here. This script used to
# rewrite the peer's kubeconfig to a LAN-reachable API endpoint and apply it as a
# remote secret, which meant the cross-host demo required the peer's Kubernetes
# API to be reachable, and quietly claimed that peering needs API access. It does
# not: the peer Gateway written below carries both the data-plane (:15008) and
# control-plane (:15012) endpoints, and that is the entire contract.

# ── Add remote peer entry ────────────────────────────────────────────────────
# Two peering styles in play depending on which lab stood the cluster up:
#
#   agentgw lab  — east-west GW lives in namespace istio-eastwest, peering is
#                  wired via the Solo Istio "peering" helm chart's remote.items[].
#   istio-gw lab — east-west GW lives in namespace istio-gateways, peering is
#                  wired via an istio-remote GatewayClass Gateway CR (the same
#                  shape `istioctl multicluster link` produces, but with the
#                  peer's LAN endpoint instead of the unreachable bridge IP).
#
# Pick the style by looking at the local cluster's east-west namespace.

step "Detecting peering style"
if kubectl --context "$LOCAL_CTX" get ns istio-eastwest >/dev/null 2>&1; then
  PEERING_STYLE=helm
  EW_NS=istio-eastwest
  log_ok "found ns istio-eastwest → using Solo Istio peering helm chart"
elif kubectl --context "$LOCAL_CTX" get ns istio-gateways >/dev/null 2>&1; then
  PEERING_STYLE=gateway-cr
  EW_NS=istio-gateways
  log_ok "found ns istio-gateways → using istio-remote Gateway CR"
else
  die "neither istio-eastwest nor istio-gateways namespace exists on $LOCAL_CTX — has quick-single.sh run?"
fi

step "Adding peering remote-peer → $PEER_NAME @ $PEER_EW_ENDPOINT"

if [[ "$PEERING_STYLE" == "helm" ]]; then
  helm upgrade --install remote-peers \
    "$PEERING_CHART" \
    --kube-context "$LOCAL_CTX" \
    --namespace "$EW_NS" \
    --version "$SOLO_ISTIO_VERSION" \
    -f - >/dev/null <<EOF
eastwest:
  create: false
remote:
  create: true
  items:
  - cluster: ${PEER_NAME}
    network: ${PEER_NAME}
    trustDomain: cluster.local
    address: ${PEER_HOST}
    hbonePort: ${PEER_HBONE_PORT}
    xdsPort: ${PEER_XDS_PORT}
EOF
  log_ok "remote-peers helm release upgraded in $EW_NS"
else
  # istio-remote Gateway CR — same address fields as the helm path, but
  # expressed as a single Gateway resource. The Solo Istio controller turns
  # this into the equivalent of `istioctl multicluster link`.
  kubectl --context "$LOCAL_CTX" apply -f - >/dev/null <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: istio-remote-peer-${PEER_NAME}
  namespace: ${EW_NS}
  annotations:
    networking.istio.io/peer-cluster: ${PEER_NAME}
    networking.istio.io/peer-network: ${PEER_NAME}
    networking.istio.io/peer-trust-domain: cluster.local
    networking.istio.io/peer-address: ${PEER_HOST}
    networking.istio.io/peer-hbone-port: "${PEER_HBONE_PORT}"
    networking.istio.io/peer-xds-port: "${PEER_XDS_PORT}"
spec:
  gatewayClassName: istio-remote
  addresses:
  - type: IPAddress
    value: ${PEER_HOST}
  listeners:
  - name: tls-hbone
    port: ${PEER_HBONE_PORT}
    protocol: TCP
  - name: tls-xds
    port: ${PEER_XDS_PORT}
    protocol: TCP
EOF
  log_ok "istio-remote Gateway CR applied in $EW_NS"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "  Peering wired from $LOCAL_CTX  →  kind-${PEER_NAME}"
echo "════════════════════════════════════════════════════════════════════"
echo ""
echo "  Local cluster:       $LOCAL_CTX"
echo "  Peer cluster:        kind-${PEER_NAME}"
echo "  Peer east-west GW:   ${PEER_HOST}  HBONE=${PEER_HBONE_PORT}  XDS=${PEER_XDS_PORT}"
echo "  Peer kube-API:       not used — discovery is istiod-to-istiod xDS"
echo ""
echo "  Verify (run on either side; both clusters should appear connected):"
echo ""
echo "    istioctl --context $LOCAL_CTX multicluster check"
echo ""
echo "${YEL}  Reminder:${RST} this script only wired the ${LOCAL_CTX} → kind-${PEER_NAME}"
echo "  direction. Run the symmetric command on the OTHER machine so its istiod"
echo "  can also discover this cluster, otherwise pod-to-pod cross-cluster"
echo "  traffic stays one-way."
echo ""
