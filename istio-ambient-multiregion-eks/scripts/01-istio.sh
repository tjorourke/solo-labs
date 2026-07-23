#!/usr/bin/env bash
# 01-istio.sh — Solo Istio ambient on BOTH EKS clusters, plain Helm (no
# operator), with a shared root CA so the two clusters can peer.
#
# Per cluster: Gateway API CRDs, cacerts (shared root + per-cluster
# intermediate), then base / istiod / cni / ztunnel. istiod gets the
# multicluster essentials: the licence, PILOT_ENABLE_K8S_SELECT_WORKLOAD_ENTRIES
# off, and its cluster/network identity. istio-system is labelled with the
# cluster's network (topology.istio.io/network) — the east-west step depends
# on it.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
require_license; require_aws

CERTS_DIR="$LAB_ROOT/.certs"
mkdir -p "$CERTS_DIR"

step "Shared root CA + per-cluster intermediates"
if [[ ! -f "$CERTS_DIR/root-ca.crt" ]]; then
  openssl genrsa -out "$CERTS_DIR/root-ca.key" 4096 2>/dev/null
  openssl req -new -x509 -days 3650 -key "$CERTS_DIR/root-ca.key" \
    -subj "/O=Solo Demo/CN=Shared Root CA" -out "$CERTS_DIR/root-ca.crt" 2>/dev/null
  ok "root CA generated"
fi
for name in "$NAME1" "$NAME2"; do
  if [[ ! -f "$CERTS_DIR/${name}-ca.crt" ]]; then
    openssl genrsa -out "$CERTS_DIR/${name}-ca.key" 4096 2>/dev/null
    cat > "$CERTS_DIR/${name}-csr.conf" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no
[req_distinguished_name]
O = Solo Demo
CN = ${name} Intermediate CA
[v3_req]
subjectAltName = URI:spiffe://cluster.local/ns/istio-system/sa/citadel
basicConstraints = CA:TRUE
keyUsage = keyCertSign, cRLSign
EOF
    openssl req -new -key "$CERTS_DIR/${name}-ca.key" -config "$CERTS_DIR/${name}-csr.conf" \
      -out "$CERTS_DIR/${name}-ca.csr" 2>/dev/null
    openssl x509 -req -days 3650 -in "$CERTS_DIR/${name}-ca.csr" \
      -CA "$CERTS_DIR/root-ca.crt" -CAkey "$CERTS_DIR/root-ca.key" -CAcreateserial \
      -extfile "$CERTS_DIR/${name}-csr.conf" -extensions v3_req \
      -out "$CERTS_DIR/${name}-ca.crt" 2>/dev/null
    ok "$name intermediate generated"
  fi
done

install_cluster() {
  local name="$1" region="$2"
  local ctx; ctx="$(ctx_of "$name" "$region")"
  [[ -n "$ctx" ]] || die "no kube context for $name ($region) — did eksctl finish?"
  step "[$name] Gateway API CRDs $GATEWAY_API_VERSION"
  kubectl --context "$ctx" apply -f \
    "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" >/dev/null
  ok "[$name] Gateway API CRDs"

  # plain-Helm installs do not ship the eastwest GatewayClass (the operator
  # does) — istiod's eastwest controller reconciles it once it exists
  kubectl --context "$ctx" apply -f - >/dev/null <<'GWC'
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: istio-eastwest
spec:
  controllerName: istio.io/eastwest-controller
GWC

  step "[$name] cacerts + licence secret + network label"
  kubectl --context "$ctx" create namespace istio-system --dry-run=client -o yaml \
    | kubectl --context "$ctx" apply -f - >/dev/null
  cat "$CERTS_DIR/${name}-ca.crt" "$CERTS_DIR/root-ca.crt" > "$CERTS_DIR/${name}-ca-chain.crt"
  kubectl --context "$ctx" -n istio-system create secret generic cacerts \
    --from-file=ca-cert.pem="$CERTS_DIR/${name}-ca.crt" \
    --from-file=ca-key.pem="$CERTS_DIR/${name}-ca.key" \
    --from-file=root-cert.pem="$CERTS_DIR/root-ca.crt" \
    --from-file=cert-chain.pem="$CERTS_DIR/${name}-ca-chain.crt" \
    --dry-run=client -o yaml | kubectl --context "$ctx" apply -f - >/dev/null
  kubectl --context "$ctx" -n istio-system create secret generic solo-istio-license \
    --from-literal=license="${SOLO_ISTIO_LICENSE_KEY}" \
    --dry-run=client -o yaml | kubectl --context "$ctx" apply -f - >/dev/null
  kubectl --context "$ctx" label ns istio-system "topology.istio.io/network=${name}" --overwrite >/dev/null
  ok "[$name] secrets + network label"

  step "[$name] Helm: base / istiod / cni / ztunnel ($SOLO_ISTIO_VERSION)"
  helm --kube-context "$ctx" upgrade -i istio-base "$ISTIO_HELM_REPO/base" \
    -n istio-system --version "$ISTIO_HELM_VERSION" --set defaultRevision=default --wait >/dev/null
  helm --kube-context "$ctx" upgrade -i istiod "$ISTIO_HELM_REPO/istiod" \
    -n istio-system --version "$ISTIO_HELM_VERSION" --wait -f - >/dev/null <<EOF
profile: ambient
global:
  hub: ${ISTIO_REGISTRY}
  tag: ${ISTIO_VERSION}
  multiCluster:
    clusterName: ${name}
  network: ${name}
istio_cni:
  enabled: true
license:
  value: ${SOLO_ISTIO_LICENSE_KEY}
env:
  # ambient peering requirement (from the verified two-cluster lab)
  PILOT_ENABLE_K8S_SELECT_WORKLOAD_ENTRIES: "false"
  # activates the eastwest gateway controller (istio-eastwest GatewayClass)
  AMBIENT_ENABLE_MULTI_NETWORK: "true"
meshConfig:
  accessLogFile: /dev/stdout
EOF
  # multicluster unlock reads SOLO_LICENSE_KEY from a Secret — wire it explicitly
  kubectl --context "$ctx" -n istio-system set env deploy/istiod \
    SOLO_LICENSE_KEY- >/dev/null 2>&1 || true
  kubectl --context "$ctx" -n istio-system patch deployment istiod --type=json -p='[
    {"op":"add","path":"/spec/template/spec/containers/0/env/-",
     "value":{"name":"SOLO_LICENSE_KEY",
              "valueFrom":{"secretKeyRef":{"name":"solo-istio-license","key":"license"}}}}
  ]' >/dev/null
  kubectl --context "$ctx" -n istio-system rollout status deploy/istiod --timeout=180s >/dev/null

  helm --kube-context "$ctx" upgrade -i istio-cni "$ISTIO_HELM_REPO/cni" \
    -n istio-system --version "$ISTIO_HELM_VERSION" --wait -f - >/dev/null <<EOF
profile: ambient
global:
  hub: ${ISTIO_REGISTRY}
  tag: ${ISTIO_VERSION}
ambient:
  dnsCapture: true
excludeNamespaces: [istio-system, kube-system]
EOF
  helm --kube-context "$ctx" upgrade -i ztunnel "$ISTIO_HELM_REPO/ztunnel" \
    -n istio-system --version "$ISTIO_HELM_VERSION" --wait -f - >/dev/null <<EOF
profile: ambient
hub: ${ISTIO_REGISTRY}
tag: ${ISTIO_VERSION}
namespace: istio-system
istioNamespace: istio-system
multiCluster:
  clusterName: ${name}
network: ${name}
env:
  LOG_FORMAT: json
EOF
  kubectl --context "$ctx" -n istio-system rollout status ds/ztunnel ds/istio-cni-node --timeout=240s >/dev/null
  ok "[$name] ambient mesh up"
}

install_cluster "$NAME1" "$REGION1"
install_cluster "$NAME2" "$REGION2"
echo
ok "both clusters running Solo ambient $SOLO_ISTIO_VERSION with a shared root CA"
