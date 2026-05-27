#!/usr/bin/env bash
# Step 3 — install Solo Enterprise Istio Ambient on both clusters via
# the Gloo Operator + ServiceMeshController CR.
#
# Prerequisites:
#   SOLO_ISTIO_LICENSE_KEY  — Solo Istio enterprise license (set in .env)
#   gcloud auth               — to pull images from us-docker.pkg.dev/soloio-img
#   helm, kubectl, kind
#
# What this script does:
#   1. Install Gateway API CRDs (v1.5.0)
#   2. Install Gloo Operator on both clusters
#   3. Create solo-istio-license Secret in istio-system
#   4. Generate shared root CA + per-cluster intermediates (shared trust domain)
#   5. Apply ServiceMeshController CR (SMC) — operator reconciles istiod+ztunnel+CNI
#   6. Patch istiod with PILOT_ENABLE_K8S_SELECT_WORKLOAD_ENTRIES + SOLO_LICENSE_KEY
#      and ztunnel with L7_ENABLED
#   7. Install east/west gateways for HBONE mesh peering
#   8. Install remote peer references + cross-apply remote secrets

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load .env if present (SOLO_ISTIO_LICENSE_KEY etc.)
[[ -f "$REPO_ROOT/.env" ]] && { set -a; source "$REPO_ROOT/.env"; set +a; }

CLUSTER1="${CLUSTER1:-kind-east}"
CLUSTER2="${CLUSTER2:-kind-west}"
CLUSTERS=("$CLUSTER1" "$CLUSTER2")
CLUSTER_NAMES=("east" "west")

OPERATOR_VERSION="${GLOO_OPERATOR_VERSION:-0.5.2}"
OPERATOR_CHART="oci://us-docker.pkg.dev/solo-public/gloo-operator-helm/gloo-operator"
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.4.0}"   # v1.5.0 ships a safe-upgrades ValidatingAdmissionPolicy that blocks SMC's bundled CRD install
SOLO_ISTIO_VERSION="${SOLO_ISTIO_VERSION:-1.29.2-patch0-solo}"
# Strip "-solo" — the operator auto-appends it when distribution=Standard.
ISTIO_VERSION="${SOLO_ISTIO_VERSION%-solo}"
ISTIO_REGISTRY="us-docker.pkg.dev/soloio-img/istio"
HELM_REPO="us-docker.pkg.dev/soloio-img/istio-helm"
EW_HBONE_NODEPORT=30015
EW_XDS_NODEPORT=30016

[[ -n "${SOLO_ISTIO_LICENSE_KEY:-}" ]] || { echo "ERROR: SOLO_ISTIO_LICENSE_KEY not set"; exit 1; }

log()    { echo "  $*"; }
log_ok() { echo "  ✓ $*"; }
step()   { echo ""; echo "==> $*"; }

# ---------- Step 1: Gateway API CRDs ----------
step "Installing Gateway API CRDs $GATEWAY_API_VERSION"
for ctx in "${CLUSTERS[@]}"; do
  log "[${ctx#kind-}] applying Gateway API CRDs..."
  kubectl --context "$ctx" apply -f \
    "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" \
    >/dev/null
  log_ok "[${ctx#kind-}] Gateway API CRDs applied"
done

# ---------- Step 2: Pre-pull Solo Istio images ----------
step "Pre-pulling Solo Istio images (requires gcloud auth)"
IMAGES=(
  "$ISTIO_REGISTRY/pilot:$ISTIO_VERSION"
  "$ISTIO_REGISTRY/proxyv2:$ISTIO_VERSION"
  "$ISTIO_REGISTRY/install-cni:$ISTIO_VERSION"
  "$ISTIO_REGISTRY/ztunnel:$ISTIO_VERSION"
)
for img in "${IMAGES[@]}"; do
  docker image inspect "$img" >/dev/null 2>&1 && { log_ok "cached: $(basename "$img")"; continue; }
  log "pulling $img..."
  docker pull --quiet "$img"
done

for i in "${!CLUSTERS[@]}"; do
  ctx="${CLUSTERS[$i]}"
  for img in "${IMAGES[@]}"; do
    log "[${ctx#kind-}] loading $(basename "$img")..."
    kind load docker-image "$img" --name "${CLUSTER_NAMES[$i]}" >/dev/null
  done
done

# ---------- Step 3: Gloo Operator ----------
step "Installing Gloo Operator $OPERATOR_VERSION"
for ctx in "${CLUSTERS[@]}"; do
  log "[${ctx#kind-}] helm install gloo-operator..."
  helm --kube-context "$ctx" upgrade --install gloo-operator "$OPERATOR_CHART" \
    --namespace gloo-system --create-namespace \
    --version "$OPERATOR_VERSION" \
    --wait --timeout 5m >/dev/null
  log_ok "[${ctx#kind-}] Gloo Operator ready"
done

# ---------- Step 4: License Secret ----------
# Must live in istio-system — istiod-gloo reads SOLO_LICENSE_KEY via secretKeyRef
# which only resolves from the pod's own namespace. The env wiring itself is
# patched on in Step 7 below.
step "Creating Solo Istio license secret in istio-system"
for ctx in "${CLUSTERS[@]}"; do
  kubectl --context "$ctx" create namespace istio-system >/dev/null 2>&1 || true
  kubectl --context "$ctx" -n istio-system create secret generic solo-istio-license \
    --from-literal=license="${SOLO_ISTIO_LICENSE_KEY}" \
    --dry-run=client -o yaml | kubectl --context "$ctx" apply -f - >/dev/null
  log_ok "[${ctx#kind-}] solo-istio-license secret created"
done

# ---------- Step 5: Shared root CA ----------
step "Generating shared root CA + per-cluster intermediates"
CERTS_DIR="$REPO_ROOT/.certs"
mkdir -p "$CERTS_DIR"

if [[ ! -f "$CERTS_DIR/root-ca.crt" ]]; then
  log "generating root CA..."
  openssl genrsa -out "$CERTS_DIR/root-ca.key" 4096 2>/dev/null
  openssl req -new -x509 -days 3650 -key "$CERTS_DIR/root-ca.key" \
    -subj "/O=Solo Demo/CN=Shared Root CA" \
    -out "$CERTS_DIR/root-ca.crt" 2>/dev/null
  log_ok "root CA generated"
fi

for name in "${CLUSTER_NAMES[@]}"; do
  if [[ ! -f "$CERTS_DIR/${name}-ca.crt" ]]; then
    log "generating intermediate for $name..."
    openssl genrsa -out "$CERTS_DIR/${name}-ca.key" 4096 2>/dev/null
    # SAN must be spiffe://cluster.local/ns/istio-system/sa/citadel
    # (required for Solo Istio cross-cluster cert-chain validation)
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
    openssl req -new -key "$CERTS_DIR/${name}-ca.key" \
      -config "$CERTS_DIR/${name}-csr.conf" \
      -out "$CERTS_DIR/${name}-ca.csr" 2>/dev/null
    openssl x509 -req -days 3650 \
      -in "$CERTS_DIR/${name}-ca.csr" \
      -CA "$CERTS_DIR/root-ca.crt" -CAkey "$CERTS_DIR/root-ca.key" \
      -CAcreateserial \
      -extfile "$CERTS_DIR/${name}-csr.conf" -extensions v3_req \
      -out "$CERTS_DIR/${name}-ca.crt" 2>/dev/null
    log_ok "$name intermediate generated"
  fi
done

for i in "${!CLUSTERS[@]}"; do
  ctx="${CLUSTERS[$i]}"
  name="${CLUSTER_NAMES[$i]}"
  log "[${name}] applying cacerts secret..."
  cat "$CERTS_DIR/${name}-ca.crt" "$CERTS_DIR/root-ca.crt" > "$CERTS_DIR/${name}-ca-chain.crt"
  kubectl --context "$ctx" create namespace istio-system --dry-run=client -o yaml \
    | kubectl --context "$ctx" apply -f - >/dev/null
  kubectl --context "$ctx" -n istio-system create secret generic cacerts \
    --from-file=ca-cert.pem="$CERTS_DIR/${name}-ca.crt" \
    --from-file=ca-key.pem="$CERTS_DIR/${name}-ca.key" \
    --from-file=root-cert.pem="$CERTS_DIR/root-ca.crt" \
    --from-file=cert-chain.pem="$CERTS_DIR/${name}-ca-chain.crt" \
    --dry-run=client -o yaml | kubectl --context "$ctx" apply -f - >/dev/null
  log_ok "[$name] cacerts secret applied"
done

# ---------- Step 6: ServiceMeshController ----------
step "Applying ServiceMeshController CRs"
for i in "${!CLUSTERS[@]}"; do
  ctx="${CLUSTERS[$i]}"
  name="${CLUSTER_NAMES[$i]}"
  log "[$name] applying SMC..."
  kubectl --context "$ctx" apply -f "$REPO_ROOT/yaml/istio/${name}-smc.yaml" >/dev/null
  log_ok "[$name] SMC applied — waiting for istiod..."
  kubectl --context "$ctx" -n istio-system wait \
    --for=condition=Available deployment/istiod-gloo \
    --timeout=300s >/dev/null
  log_ok "[$name] istiod-gloo ready"
done

# ---------- Step 7: Patch istiod + ztunnel env vars ----------
# Three things go in here that the SMC schema doesn't expose:
#   - PILOT_ENABLE_K8S_SELECT_WORKLOAD_ENTRIES=false  → istiod (Ambient peering)
#   - SOLO_LICENSE_KEY (from Secret)                  → istiod (unlocks MultiCluster)
#   - L7_ENABLED=true                                 → ztunnel (L7 HBONE across waypoints)
#
# L7_ENABLED belongs on ztunnel, NOT istiod — confirmed by Solo Ambient multicluster
# troubleshooting docs. SOLO_LICENSE_KEY is the only var pilot-discovery reads to
# unlock the multicluster feature; LICENSE_KEY / GLOO_LICENSE_KEY do not work.
step "Patching istiod with required env vars + SOLO_LICENSE_KEY"
for i in "${!CLUSTERS[@]}"; do
  ctx="${CLUSTERS[$i]}"
  name="${CLUSTER_NAMES[$i]}"
  kubectl --context "$ctx" -n istio-system patch deployment istiod-gloo \
    --type=json -p='[
      {"op":"add","path":"/spec/template/spec/containers/0/env/-",
       "value":{"name":"PILOT_ENABLE_K8S_SELECT_WORKLOAD_ENTRIES","value":"false"}},
      {"op":"add","path":"/spec/template/spec/containers/0/env/-",
       "value":{"name":"SOLO_LICENSE_KEY",
                "valueFrom":{"secretKeyRef":{"name":"solo-istio-license","key":"license"}}}}
    ]' >/dev/null
  log_ok "[$name] istiod env patched"
done

step "Patching ztunnel L7_ENABLED"
for i in "${!CLUSTERS[@]}"; do
  ctx="${CLUSTERS[$i]}"
  name="${CLUSTER_NAMES[$i]}"
  end=$(( $(date +%s) + 120 ))
  until kubectl --context "$ctx" -n istio-system get daemonset ztunnel >/dev/null 2>&1; do
    [[ $(date +%s) -ge $end ]] && { echo "ztunnel DaemonSet not created in 2m"; exit 1; }
    sleep 3
  done
  kubectl --context "$ctx" -n istio-system patch daemonset ztunnel \
    --type=json -p='[
      {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"L7_ENABLED","value":"true"}}
    ]' >/dev/null
  log_ok "[$name] ztunnel env patched"
done

# Create istiod alias Service (enterprise-agentgateway-waypoint binary
# hardcodes CA_ADDRESS=istiod.istio-system.svc:15012 but Gloo Operator
# names it istiod-gloo).
step "Creating istiod alias Service"
for ctx in "${CLUSTERS[@]}"; do
  kubectl --context "$ctx" apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: istiod
  namespace: istio-system
spec:
  selector:
    app: istiod
  ports:
    - name: grpc-xds
      port: 15010
    - name: https-dns
      port: 15012
    - name: https-webhook
      port: 443
      targetPort: 15017
    - name: http-monitoring
      port: 15014
EOF
  log_ok "[${ctx#kind-}] istiod alias Service created"
done

# ---------- Step 8: East-west gateways (HBONE mesh fabric) ----------
# The Istio east-west gateway is the HBONE fabric for cross-cluster mesh
# traffic. The enterprise-agentgateway-waypoint sits on TOP of this at L7.
step "Installing east/west gateways (HBONE fabric)"
for i in "${!CLUSTERS[@]}"; do
  ctx="${CLUSTERS[$i]}"
  name="${CLUSTER_NAMES[$i]}"
  kubectl --context "$ctx" create namespace istio-eastwest --dry-run=client -o yaml \
    | kubectl --context "$ctx" apply -f - >/dev/null
  kubectl --context "$ctx" label ns istio-system \
    "topology.istio.io/network=${name}" --overwrite >/dev/null

  cat > /tmp/ew-${name}.yaml <<EOF
eastwest:
  create: true
  cluster: ${name}
  network: ${name}
  dataplaneServiceTypes:
    - nodeport
  service:
    spec:
      type: NodePort
      ports:
        - name: tls-hbone
          port: 15008
          nodePort: ${EW_HBONE_NODEPORT}
          protocol: TCP
        - name: tls-xds
          port: 15012
          nodePort: ${EW_XDS_NODEPORT}
          protocol: TCP
remote:
  create: false
EOF
  helm --kube-context "$ctx" upgrade --install "peering-${name}" \
    "oci://${HELM_REPO}/peering" \
    --namespace istio-eastwest \
    --version "$SOLO_ISTIO_VERSION" \
    -f "/tmp/ew-${name}.yaml" \
    --wait --timeout 5m >/dev/null
  log_ok "[$name] east-west GW installed"
done

# Discover node IPs on the kind docker bridge.
EAST_IP="$(docker inspect "east-control-plane" --format '{{ .NetworkSettings.Networks.kind.IPAddress }}')"
WEST_IP="$(docker inspect "west-control-plane" --format '{{ .NetworkSettings.Networks.kind.IPAddress }}')"
log "east node IP: $EAST_IP"
log "west node IP: $WEST_IP"

# Apply remote peer references (each cluster learns the other's east-west GW).
for i in "${!CLUSTERS[@]}"; do
  ctx="${CLUSTERS[$i]}"
  name="${CLUSTER_NAMES[$i]}"
  cat > /tmp/remote-${name}.yaml <<EOF
eastwest:
  create: false
remote:
  create: true
  items:
EOF
  for j in "${!CLUSTERS[@]}"; do
    [[ "$j" == "$i" ]] && continue
    peer_name="${CLUSTER_NAMES[$j]}"
    peer_ip="$(docker inspect "${peer_name}-control-plane" \
      --format '{{ .NetworkSettings.Networks.kind.IPAddress }}')"
    cat >> /tmp/remote-${name}.yaml <<EOF
    - cluster: ${peer_name}
      network: ${peer_name}
      trustDomain: cluster.local
      address: ${peer_ip}
      hbonePort: ${EW_HBONE_NODEPORT}
      xdsPort: ${EW_XDS_NODEPORT}
EOF
  done
  helm --kube-context "$ctx" upgrade --install "remote-${name}" \
    "oci://${HELM_REPO}/peering" \
    --namespace istio-eastwest \
    --version "$SOLO_ISTIO_VERSION" \
    -f "/tmp/remote-${name}.yaml" >/dev/null
  log_ok "[$name] remote peers configured"
done

# ---------- Step 9: Remote secrets (control-plane discovery) ----------
step "Cross-applying istio-remote-secrets"
for i in "${!CLUSTERS[@]}"; do
  src_ctx="${CLUSTERS[$i]}"
  src_name="${CLUSTER_NAMES[$i]}"
  for j in "${!CLUSTERS[@]}"; do
    [[ "$j" == "$i" ]] && continue
    dst_ctx="${CLUSTERS[$j]}"
    dst_name="${CLUSTER_NAMES[$j]}"
    log "[$dst_name] installing remote secret for $src_name..."
    SA_SECRET="$(kubectl --context "$src_ctx" -n istio-system \
      get sa istio-reader-service-account -o jsonpath='{.secrets[0].name}' 2>/dev/null || true)"
    TOKEN="$(kubectl --context "$src_ctx" -n istio-system create token \
      istio-reader-service-account --duration=8760h 2>/dev/null)"
    SERVER="$(kubectl --context "$src_ctx" config view \
      --minify --flatten -o jsonpath='{.clusters[0].cluster.server}')"
    CA="$(kubectl --context "$src_ctx" config view \
      --minify --flatten -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
    kubectl --context "$dst_ctx" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: istio-remote-secret-${src_name}
  namespace: istio-system
  labels:
    istio.io/cluster: ${src_name}
    networking.istio.io/remote: "true"
type: Opaque
stringData:
  ${src_name}: |
    apiVersion: v1
    kind: Config
    clusters:
    - cluster:
        certificate-authority-data: ${CA}
        server: ${SERVER}
      name: ${src_name}
    contexts:
    - context:
        cluster: ${src_name}
        user: ${src_name}
      name: ${src_name}
    current-context: ${src_name}
    users:
    - name: ${src_name}
      user:
        token: ${TOKEN}
EOF
    log_ok "[$dst_name] remote secret for $src_name applied"
  done
done

# ---------- Step 10: Label workload namespaces ----------
step "Labelling workload namespaces with topology.istio.io/network"
for i in "${!CLUSTERS[@]}"; do
  ctx="${CLUSTERS[$i]}"
  name="${CLUSTER_NAMES[$i]}"
  for ns in ai-demo agentgateway-system; do
    kubectl --context "$ctx" create namespace "$ns" --dry-run=client -o yaml \
      | kubectl --context "$ctx" apply -f - >/dev/null
    kubectl --context "$ctx" label namespace "$ns" \
      "topology.istio.io/network=${name}" \
      "istio.io/dataplane-mode=ambient" \
      --overwrite >/dev/null
  done
  log_ok "[$name] namespaces labelled"
done

echo ""
echo "==> Solo Istio Ambient installed on both clusters"
echo "    east node IP : $EAST_IP"
echo "    west node IP : $WEST_IP"
echo ""
echo "Next: ./scripts/04-agentgateway.sh"
