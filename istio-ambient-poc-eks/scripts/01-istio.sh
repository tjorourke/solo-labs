#!/usr/bin/env bash
# 01-istio.sh — Solo Istio ambient on BOTH clusters by plain Helm, with a shared
# root CA and a per-cluster intermediate, so the two meshes can later be linked.
#
# Per cluster: Gateway API CRDs, cacerts, the licence, the network label, then
# base / istiod / cni / ztunnel. Every value the docs ask for in a multicluster
# install is a plain Helm value below, nothing hidden in an operator.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require helm; require openssl
require_license; require_aws; require_contexts

CERTS="$STATE_DIR/certs"; mkdir -p "$CERTS"

# ── one offline root, one intermediate per cluster ────────────────────────────
# The root key never goes into a cluster. Each cluster's istiod only ever holds
# its own intermediate (cacerts). Both intermediates chain to the same root, and
# that shared root is the whole basis for cross-cluster mTLS.
step "Shared root CA + per-cluster intermediates ($CERTS)"
if [[ ! -f "$CERTS/root-ca.crt" ]]; then
  openssl genrsa -out "$CERTS/root-ca.key" 4096 2>/dev/null
  openssl req -new -x509 -days 3650 -key "$CERTS/root-ca.key" \
    -subj "/O=Ambient POC/CN=POC Root CA" -out "$CERTS/root-ca.crt" 2>/dev/null
  ok "root CA generated (10y, offline)"
fi
make_intermediate() {   # make_intermediate <cluster> [suffix]
  local name="$1" suffix="${2:-}" base="$CERTS/${1}${2:-}"
  cat > "$base-csr.conf" <<CONF
[req]
distinguished_name = dn
req_extensions = v3_req
prompt = no
[dn]
O = Ambient POC
CN = ${name} Intermediate CA${suffix:+ $suffix}
[v3_req]
subjectAltName = URI:spiffe://cluster.local/ns/istio-system/sa/citadel
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
CONF
  openssl genrsa -out "$base-ca.key" 4096 2>/dev/null
  openssl req -new -key "$base-ca.key" -config "$base-csr.conf" -out "$base-ca.csr" 2>/dev/null
  openssl x509 -req -days 730 -in "$base-ca.csr" -CA "$CERTS/root-ca.crt" -CAkey "$CERTS/root-ca.key" \
    -CAcreateserial -extfile "$base-csr.conf" -extensions v3_req -out "$base-ca.crt" 2>/dev/null
  cat "$base-ca.crt" "$CERTS/root-ca.crt" > "$base-chain.crt"
}
for name in "$CLUSTER_A" "$CLUSTER_B"; do
  [[ -f "$CERTS/${name}-ca.crt" ]] || { make_intermediate "$name"; ok "$name intermediate generated (2y)"; }
done

install_cluster() {   # install_cluster <ctx/cluster> <trust-domain> <extra ztunnel env yaml>
  local name="$1" td="$2" zt_extra="${3:-}"
  step "[$name] Gateway API CRDs $GATEWAY_API_VERSION"
  kubectl --context "$name" apply -f \
    "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" >/dev/null
  ok "[$name] Gateway API CRDs"

  step "[$name] istio-system: cacerts + licence + network label"
  kubectl --context "$name" create namespace istio-system --dry-run=client -o yaml | kubectl --context "$name" apply -f - >/dev/null
  kubectl --context "$name" -n istio-system create secret generic cacerts \
    --from-file=ca-cert.pem="$CERTS/${name}-ca.crt" \
    --from-file=ca-key.pem="$CERTS/${name}-ca.key" \
    --from-file=root-cert.pem="$CERTS/root-ca.crt" \
    --from-file=cert-chain.pem="$CERTS/${name}-chain.crt" \
    --dry-run=client -o yaml | kubectl --context "$name" apply -f - >/dev/null
  kubectl --context "$name" label ns istio-system "topology.istio.io/network=${MESH_NETWORK}" --overwrite >/dev/null
  ok "[$name] cacerts (intermediate + shared root), network=$MESH_NETWORK"

  step "[$name] Helm: base / istiod / cni / ztunnel ($SOLO_ISTIO_VERSION, trust domain $td)"
  helm --kube-context "$name" upgrade -i istio-base "$ISTIO_HELM_REPO/base" \
    -n istio-system --version "$SOLO_ISTIO_VERSION" --set defaultRevision=default --wait >/dev/null
  helm --kube-context "$name" upgrade -i istiod "$ISTIO_HELM_REPO/istiod" \
    -n istio-system --version "$SOLO_ISTIO_VERSION" --wait -f - >/dev/null <<EOV
profile: ambient
global:
  hub: ${ISTIO_REGISTRY}
  tag: ${ISTIO_TAG}
  multiCluster:
    clusterName: ${name}
  network: ${MESH_NETWORK}
istio_cni:
  enabled: true
license:
  value: ${SOLO_ISTIO_LICENSE_KEY}
platforms:
  peering:
    enabled: true                    # multicluster peering (Enterprise licence)
env:
  PILOT_ENABLE_IP_AUTOALLOCATE: "true"     # IPs for <svc>.<ns>.mesh.internal global hostnames
  PEERING_ENABLE_FLAT_NETWORKS: "true"     # flat network: remote services get WorkloadEntries with direct pod IPs
  PILOT_SKIP_VALIDATE_TRUST_DOMAIN: "true" # required with a per-cluster trust domain
  DISABLE_LEGACY_MULTICLUSTER: "true"      # peering, not remote secrets
  REQUIRE_3P_TOKEN: "false"                # step 7: accept the VM's ServiceAccount token (EKS audience)
  AUTO_RELOAD_PLUGIN_CERTS: "true"         # scenario 7: pick up a new cacerts without a restart
meshConfig:
  accessLogFile: /dev/stdout
  trustDomain: ${td}
EOV
  helm --kube-context "$name" upgrade -i istio-cni "$ISTIO_HELM_REPO/cni" \
    -n istio-system --version "$SOLO_ISTIO_VERSION" --wait -f - >/dev/null <<EOV
profile: ambient
global:
  hub: ${ISTIO_REGISTRY}
  tag: ${ISTIO_TAG}
ambient:
  dnsCapture: true                   # needed for .mesh.internal lookups (multicluster check tests this)
excludeNamespaces: [istio-system, kube-system]
EOV
  helm --kube-context "$name" upgrade -i ztunnel "$ISTIO_HELM_REPO/ztunnel" \
    -n istio-system --version "$SOLO_ISTIO_VERSION" --wait -f - >/dev/null <<EOV
profile: ambient
hub: ${ISTIO_REGISTRY}
tag: ${ISTIO_TAG}
variant: distroless
istioNamespace: istio-system
multiCluster:
  clusterName: ${name}
network: ${MESH_NETWORK}
l7Telemetry:
  accessLog:
    enabled: true                    # explicit: 1.31 flips this default to false
env:
  L7_ENABLED: "true"
  SKIP_VALIDATE_TRUST_DOMAIN: "true"
  WAYPOINTS_ALWAYS_USE_HOSTNAME: "true"    # flat network: address waypoints by hostname, not (possibly remote) pod IP
${zt_extra}
EOV
  kubectl --context "$name" -n istio-system rollout status ds/ztunnel ds/istio-cni-node --timeout=300s >/dev/null
  ok "[$name] ambient mesh up"
}

# eks-a shortens the workload certificate lifetime to 30 minutes so scenario 7
# can show a live rotation. eks-b keeps the 24h default for comparison.
install_cluster "$CLUSTER_A" "$TRUST_DOMAIN_A" '  SECRET_TTL: "30m"'
install_cluster "$CLUSTER_B" "$TRUST_DOMAIN_B"

echo
for c in "$CLUSTER_A" "$CLUSTER_B"; do
  echo "[$c]"; kubectl --context "$c" -n istio-system get pods -o wide --no-headers | awk '{print "   "$1, $3}'
done
ok "both clusters run Solo ambient $SOLO_ISTIO_VERSION under one root CA"
