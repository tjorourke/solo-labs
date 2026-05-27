#!/usr/bin/env bash
# peer-with.sh — Consume a peer bundle from the OTHER machine and finish the
# peering on this side. Pairs with `expose-ew-on-host.sh` on the peer (which
# republishes that machine's east-west GW on its LAN IP).
#
# What this does on the LOCAL cluster:
#   1. Extracts the peer bundle (root-ca.{crt,key}, istio-remote-secret-<peer>.yaml,
#      cluster-name.txt, eastwest-ip.txt).
#   2. Verifies the local cacerts secret was signed by the same root CA the bundle
#      ships. (If not, the peering will silently fail mTLS — better to bail now.)
#   3. Rewrites the bundle's `istio-remote-secret-<peer>.yaml` so the embedded
#      kubeconfig's `server:` points at the peer's LAN-reachable host:port (the
#      bundle captured the in-cluster URL, which won't resolve cross-host).
#   4. Applies the rewritten remote-secret on the local cluster — istiod-gloo
#      uses it to read the peer's k8s API.
#   5. Adds a `remote.items[]` entry to the local `peering` helm release so the
#      local data plane knows where the peer's east-west GW lives.
#
# Usage:
#   ./scripts/peer-with.sh <local-cluster-name> <path/to/peer-bundle.tar.gz> <peer-ew-host:port>
#
# Example (peer is on 192.168.1.42, peer ran expose-ew-on-host.sh, which gave
# 192.168.1.42:15008 as the HBONE endpoint):
#   ./scripts/peer-with.sh green /tmp/peer-bundle-blue.tar.gz 192.168.1.42:15008
#
# Env overrides:
#   PEER_API_HOST_PORT — host:port of the peer's kube API server, LAN-reachable.
#                        If unset, defaults to "<peer-ew-host>:6443" (a separate
#                        socat tunnel must be running on the peer for port 6443
#                        — most operators front the kind control-plane port
#                        instead and set this explicitly).
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
[[ -f "$BUNDLE_INNER/istio-remote-secret-${PEER_NAME}.yaml" ]] \
  || die "bundle missing istio-remote-secret-${PEER_NAME}.yaml"
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

# ── Rewrite remote-secret kubeconfig server URL ──────────────────────────────

step "Rewriting peer remote-secret to point at LAN-reachable kube API"
REMOTE_SECRET_IN="$BUNDLE_INNER/istio-remote-secret-${PEER_NAME}.yaml"
REMOTE_SECRET_OUT="$TMP_DIR/istio-remote-secret-${PEER_NAME}.lan.yaml"

PEER_API_HOST_PORT_DEFAULT="${PEER_HOST}:6443"
PEER_API_HOST_PORT="${PEER_API_HOST_PORT:-$PEER_API_HOST_PORT_DEFAULT}"
log "  using peer kube-API endpoint: https://${PEER_API_HOST_PORT}"

# The remote-secret YAML can be in two shapes depending on how it was generated:
#   - `data:` block — value is base64-encoded kubeconfig (older istioctl path)
#   - `stringData:` block — value is inline-YAML kubeconfig (`istioctl
#     create-remote-secret` default since at least 1.20+)
# Handle both: detect the block kind, rewrite every `server: https://...`
# line in each embedded kubeconfig (decode/re-encode for base64, in-place
# regex for stringData).
python3 - "$REMOTE_SECRET_IN" "$REMOTE_SECRET_OUT" "https://${PEER_API_HOST_PORT}" <<'PY'
import base64, re, sys

src, dst, server = sys.argv[1], sys.argv[2], sys.argv[3]

with open(src, "r") as f:
    raw = f.read()

server_rx = re.compile(r"(?m)^(\s*server:\s*).*$")

# Try stringData first — that's what istioctl create-remote-secret emits today.
sd = re.search(r"(?ms)^stringData:\s*\n(?P<body>(?:[ \t]+[^\n]*(?:\n|$))+)", raw)
if sd:
    body = sd.group("body")
    new_body, n = server_rx.subn(r"\1" + server, body)
    if n == 0:
        sys.exit("ERROR: no `server:` line found in stringData kubeconfig")
    out = raw[:sd.start("body")] + new_body + raw[sd.end("body"):]
    with open(dst, "w") as f:
        f.write(out)
    print(f"  patched {n} server: line(s) in stringData block", file=sys.stderr)
    sys.exit(0)

# Fallback: legacy base64 `data:` block.
m = re.search(r"^data:\s*\n((?:[ \t]+[^\n]+\n)+)", raw, re.M)
if not m:
    sys.exit("ERROR: no `stringData:` or `data:` block found in remote-secret YAML")

block = m.group(1)
patched_lines = []
patched = False
for ln in block.splitlines(keepends=False):
    km = re.match(r"^([ \t]+)([^:\s]+):\s*(\S.*)$", ln)
    if not km:
        patched_lines.append(ln)
        continue
    indent, key, val = km.group(1), km.group(2), km.group(3)
    try:
        decoded = base64.b64decode(val).decode("utf-8")
    except Exception:
        patched_lines.append(ln)
        continue
    new_decoded, n = server_rx.subn(r"\1" + server, decoded)
    if n == 0:
        sys.exit("ERROR: no `server:` field in embedded base64 kubeconfig")
    new_val = base64.b64encode(new_decoded.encode("utf-8")).decode("ascii")
    patched_lines.append(f"{indent}{key}: {new_val}")
    patched = True

if not patched:
    sys.exit("ERROR: failed to patch any base64 kubeconfig blob in remote-secret")

new_block = "\n".join(patched_lines) + "\n"
out = raw[:m.start(1)] + new_block + raw[m.end(1):]
with open(dst, "w") as f:
    f.write(out)
PY
log_ok "rewrote server: → https://${PEER_API_HOST_PORT}"

# ── Apply rewritten remote-secret on local cluster ───────────────────────────

step "Applying remote-secret on $LOCAL_CTX"
kubectl --context "$LOCAL_CTX" apply -f "$REMOTE_SECRET_OUT" >/dev/null
log_ok "istio-remote-secret-${PEER_NAME} applied on $LOCAL_CTX"

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
echo "  Peer kube-API:       https://${PEER_API_HOST_PORT}"
echo "  Peer east-west GW:   ${PEER_HOST}  HBONE=${PEER_HBONE_PORT}  XDS=${PEER_XDS_PORT}"
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
