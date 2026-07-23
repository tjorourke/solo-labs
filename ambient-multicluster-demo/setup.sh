#!/usr/bin/env bash
# setup.sh — the ONE standup script for the two-part ambient demo.
#
# Stands up EVERYTHING the demo notebook needs, so demo.ipynb contains only the
# demo (no helm, no cluster plumbing):
#
#   1. Two kind clusters: mesh1 + mesh2 (unique names — no clash with other labs)
#   2. MetalLB on both (pools inside the kind Docker net: .140-.150 / .160-.170)
#   3. Shared root CA + per-cluster intermediate → cacerts (one root of trust)
#   4. Gateway API CRDs
#   5. Solo Istio AMBIENT on both, plain Helm (base/istiod/cni/ztunnel) with the
#      multicluster values, licence, per-cluster trust domain and JSON logs set
#      as VALUES (no post-hoc patches)
#   6. East-west gateways + peering: istioctl multicluster expose + link
#   7. Gloo UI (Gloo Platform mgmt plane on mesh1, agents on BOTH clusters →
#      the service graph spans both)
#   8. Solo Enterprise for agentgateway on both clusters (ingress + waypoint
#      GatewayClasses for both demo parts)
#   9. Keycloak IdP on mesh1 (Part 2's JWT sections)
#
# Usage:
#   ./setup.sh                 — full standup (~15-20 min first run)
#   ./setup.sh teardown        — delete both clusters + certs
#
# Licences: SOLO_ISTIO_LICENSE_KEY + AGENTGATEWAY_LICENSE_KEY (+ optional
# GLOO_PLATFORM_LICENSE_KEY, falls back to SOLO_ISTIO_LICENSE_KEY). Export them
# or point SECRETS_FILE at a file that does.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/scripts/lib.sh"
LAB_ROOT="$SCRIPT_DIR"
CERTS_DIR="$LAB_ROOT/.certs"

# ── Teardown ──────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "teardown" ]]; then
  step "Tearing down the ambient-demo clusters"
  pkill -f "port-forward.*gloo-mesh-ui" 2>/dev/null || true
  kind delete cluster --name "$CLUSTER1_NAME" 2>/dev/null && ok "$CLUSTER1_NAME deleted" || true
  kind delete cluster --name "$CLUSTER2_NAME" 2>/dev/null && ok "$CLUSTER2_NAME deleted" || true
  rm -rf "$CERTS_DIR" && ok ".certs/ removed" || true
  echo ""; echo "Done."; exit 0
fi

# ── Prereqs ───────────────────────────────────────────────────────────────────
step "Checking prereqs"
require kind; require kubectl; require helm; require docker; require openssl
require gcloud; require jq; require curl
check_docker; check_gcloud; require_secrets
ok "tools + licences present"

# ── Solo istioctl (matching version — has multicluster expose/link/check) ─────
step "Solo istioctl ${SOLO_ISTIO_VERSION}"
if [[ ! -x "$ISTIOCTL" ]]; then
  mkdir -p "$ISTIOCTL_BIN_DIR"
  OS=osx; [[ "$(uname -s)" == "Linux" ]] && OS=linux
  ARCH="$(uname -m)"
  TMP="$(mktemp -d)"
  URL="https://storage.googleapis.com/soloio-istio-binaries/release/${SOLO_ISTIO_VERSION}/istio-${SOLO_ISTIO_VERSION}-${OS}-${ARCH}.tar.gz"
  log "downloading $URL"
  curl -fsSL "$URL" -o "$TMP/istio.tar.gz" || die "could not download Solo istioctl ${SOLO_ISTIO_VERSION}"
  tar xzf "$TMP/istio.tar.gz" -C "$TMP"
  cp "$TMP/istio-${SOLO_ISTIO_VERSION}/bin/istioctl" "$ISTIOCTL"
  chmod +x "$ISTIOCTL"; rm -rf "$TMP"
fi
ok "istioctl: $ISTIOCTL ($("$ISTIOCTL" version --remote=false 2>/dev/null | head -1))"

# ── Step 1: kind clusters ─────────────────────────────────────────────────────
step "Creating kind clusters ($CLUSTER1_NAME + $CLUSTER2_NAME)"
for NAME in "$CLUSTER1_NAME" "$CLUSTER2_NAME"; do
  if kind get clusters 2>/dev/null | grep -qx "$NAME"; then
    log "[$NAME] already exists — skipping"
  else
    kind create cluster --config "$LAB_ROOT/kind/${NAME}.yaml"
    ok "[$NAME] created"
  fi
done

# ── Step 2: MetalLB ───────────────────────────────────────────────────────────
step "Installing MetalLB $METALLB_VERSION"
KIND_CIDR="$(docker network inspect kind \
  --format '{{range .IPAM.Config}}{{println .Subnet}}{{end}}' 2>/dev/null \
  | grep -v ':' | head -1)"
[[ -n "$KIND_CIDR" ]] || die "kind Docker network not found"
# Pool must sit INSIDE the kind Docker subnet or cross-cluster HBONE fails.
# Take the first THREE octets of the actual subnet (it may be a /24).
BASE="$(echo "$KIND_CIDR" | cut -d. -f1,2,3)"
log "kind network: $KIND_CIDR  (pool base: $BASE — mesh1 .140-.150, mesh2 .160-.170)"

for CTX in "$CLUSTER1" "$CLUSTER2"; do
  kubectl --context "$CTX" apply -f \
    "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml" \
    >/dev/null
done
for CTX in "$CLUSTER1" "$CLUSTER2"; do
  kubectl --context "$CTX" -n metallb-system wait \
    --for=condition=Ready pod -l app=metallb,component=controller --timeout=120s >/dev/null
  ok "[${CTX#kind-}] MetalLB controller ready"
done

kubectl --context "$CLUSTER1" apply -f - >/dev/null <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata: { name: kind-pool, namespace: metallb-system }
spec:
  addresses: ["${BASE}.140-${BASE}.150"]
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata: { name: kind-l2, namespace: metallb-system }
EOF
kubectl --context "$CLUSTER2" apply -f - >/dev/null <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata: { name: kind-pool, namespace: metallb-system }
spec:
  addresses: ["${BASE}.160-${BASE}.170"]
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata: { name: kind-l2, namespace: metallb-system }
EOF
ok "MetalLB pools configured"

# ── Step 3: shared root CA + per-cluster intermediates ────────────────────────
step "Shared root of trust (root CA + per-cluster intermediates → cacerts)"
mkdir -p "$CERTS_DIR"
if [[ ! -f "$CERTS_DIR/root-ca.crt" ]]; then
  openssl genrsa -out "$CERTS_DIR/root-ca.key" 4096 2>/dev/null
  openssl req -new -x509 -days 3650 -key "$CERTS_DIR/root-ca.key" \
    -subj "/O=Solo Demo/CN=Shared Root CA" -out "$CERTS_DIR/root-ca.crt" 2>/dev/null
  ok "root CA generated"
fi
for NAME in "$CLUSTER1_NAME" "$CLUSTER2_NAME"; do
  if [[ ! -f "$CERTS_DIR/${NAME}-ca.crt" ]]; then
    openssl genrsa -out "$CERTS_DIR/${NAME}-ca.key" 4096 2>/dev/null
    cat > "$CERTS_DIR/${NAME}-csr.conf" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no
[req_distinguished_name]
O = Solo Demo
CN = ${NAME} Intermediate CA
[v3_req]
subjectAltName = URI:spiffe://cluster.local/ns/istio-system/sa/citadel
basicConstraints = CA:TRUE
keyUsage = keyCertSign, cRLSign
EOF
    openssl req -new -key "$CERTS_DIR/${NAME}-ca.key" -config "$CERTS_DIR/${NAME}-csr.conf" \
      -out "$CERTS_DIR/${NAME}-ca.csr" 2>/dev/null
    openssl x509 -req -days 3650 -in "$CERTS_DIR/${NAME}-ca.csr" \
      -CA "$CERTS_DIR/root-ca.crt" -CAkey "$CERTS_DIR/root-ca.key" -CAcreateserial \
      -extfile "$CERTS_DIR/${NAME}-csr.conf" -extensions v3_req \
      -out "$CERTS_DIR/${NAME}-ca.crt" 2>/dev/null
    ok "[$NAME] intermediate CA generated"
  fi
done
for CTX in "$CLUSTER1" "$CLUSTER2"; do
  NAME="${CTX#kind-}"
  cat "$CERTS_DIR/${NAME}-ca.crt" "$CERTS_DIR/root-ca.crt" > "$CERTS_DIR/${NAME}-ca-chain.crt"
  kubectl --context "$CTX" create namespace "$ISTIO_SYSTEM_NS" --dry-run=client -o yaml \
    | kubectl --context "$CTX" apply -f - >/dev/null
  kubectl --context "$CTX" -n "$ISTIO_SYSTEM_NS" create secret generic cacerts \
    --from-file=ca-cert.pem="$CERTS_DIR/${NAME}-ca.crt" \
    --from-file=ca-key.pem="$CERTS_DIR/${NAME}-ca.key" \
    --from-file=root-cert.pem="$CERTS_DIR/root-ca.crt" \
    --from-file=cert-chain.pem="$CERTS_DIR/${NAME}-ca-chain.crt" \
    --dry-run=client -o yaml | kubectl --context "$CTX" apply -f - >/dev/null
  ok "[$NAME] cacerts applied"
done

# ── Step 4: Gateway API CRDs ──────────────────────────────────────────────────
step "Installing Gateway API CRDs $GATEWAY_API_VERSION"
for CTX in "$CLUSTER1" "$CLUSTER2"; do
  kubectl --context "$CTX" apply --server-side -f \
    "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" \
    >/dev/null
  ok "[${CTX#kind-}] Gateway API CRDs applied"
done

# ── Step 5: Gloo UI (start EARLY in the background — it takes the longest) ────
# Gloo Platform mgmt server + agent + UI on mesh1. No Istio dependency, so kick
# it off now and check it at the end. mesh2's agent is registered after peering.
GLOO_LOG=/tmp/ambient-demo-gloo-install.log
if [[ "${SKIP_GLOO_UI:-false}" == "true" ]]; then
  step "Skipping Gloo UI (SKIP_GLOO_UI=true)"
else
  step "Gloo UI: mgmt plane install starting in the background (log: $GLOO_LOG)"
  (
    set -Eeuo pipefail
    helm repo add gloo-platform https://storage.googleapis.com/gloo-platform/helm-charts || true
    helm repo update gloo-platform
    kubectl --context "$CLUSTER1" create namespace "$GLOO_MESH_NS" --dry-run=client -o yaml \
      | kubectl --context "$CLUSTER1" apply -f -
    helm --kube-context "$CLUSTER1" upgrade -i gloo-platform-crds gloo-platform/gloo-platform-crds \
      -n "$GLOO_MESH_NS" --version "$GLOO_PLATFORM_VERSION" --wait --timeout 5m
    # register mesh1 BEFORE the main install or the agent crashloops
    kubectl --context "$CLUSTER1" apply -f - <<REG
apiVersion: admin.gloo.solo.io/v2
kind: KubernetesCluster
metadata: { name: ${CLUSTER1_NAME}, namespace: ${GLOO_MESH_NS} }
spec: { clusterDomain: cluster.local }
REG
    helm --kube-context "$CLUSTER1" upgrade -i gloo-platform gloo-platform/gloo-platform \
      -n "$GLOO_MESH_NS" --version "$GLOO_PLATFORM_VERSION" -f - <<VALUES
common: { cluster: ${CLUSTER1_NAME} }
licensing:
  glooMeshLicenseKey: "${GLOO_PLATFORM_LICENSE_KEY:-$SOLO_ISTIO_LICENSE_KEY}"
glooMgmtServer:
  enabled: true
  createGlobalWorkspace: true
  serviceType: LoadBalancer
glooUi: { enabled: true, serviceType: ClusterIP }
glooAgent:
  enabled: true
  relay: { serverAddress: gloo-mesh-mgmt-server.${GLOO_MESH_NS}:9900 }
prometheus: { enabled: true }
redis: { deployment: { enabled: true } }
telemetryCollector: { enabled: true }
telemetryGateway:
  enabled: true
  service: { type: LoadBalancer }
glooInsightsEngine: { enabled: true }
VALUES
    echo "GLOO INSTALL DONE"
  ) > "$GLOO_LOG" 2>&1 &
  GLOO_PID=$!
  ok "Gloo mgmt plane installing in the background (pid $GLOO_PID)"
fi

# ── Step 6: pre-pull Solo Istio images and load into both clusters ────────────
step "Pre-pulling Solo Istio images ($ISTIO_VERSION)"
for IMG in $(solo_istio_images); do
  docker image inspect "$IMG" >/dev/null 2>&1 || { log "pulling $IMG …"; docker pull --quiet --platform "$KIND_PLATFORM" "$IMG" >/dev/null; }
done
# Pipe docker save straight into ctr on each node: kind's containerd chokes on
# multi-arch indexes via `kind load` (--all-platforms digest error on Apple Silicon).
for NAME in "$CLUSTER1_NAME" "$CLUSTER2_NAME"; do
  loaded=0; skipped=0
  for ROLE in control-plane worker; do
    NODE="${NAME}-${ROLE}"
    for IMG in $(solo_istio_images); do
      if docker exec "$NODE" ctr -n k8s.io images ls -q 2>/dev/null | grep -qx "$IMG"; then
        skipped=$((skipped+1)); continue
      fi
      docker save "$IMG" | docker exec --privileged -i "$NODE" ctr -n k8s.io images import - >/dev/null
      loaded=$((loaded+1))
    done
  done
  ok "[$NAME] images loaded: $loaded new, $skipped already present"
done

# ── Step 7: Solo Istio ambient via Helm (multicluster values, no operator) ────
# Everything the operator would hide is a plain Helm VALUE here: the licence,
# the per-cluster trust domain (= cluster name, NOT cluster.local — Part 2's
# whole story), cluster/network identity for peering, JSON ztunnel logs.
install_ambient() {
  local ctx="$1" name="$2"
  step "[$name] Helm: base / istiod / cni / ztunnel ($SOLO_ISTIO_VERSION)"
  helm --kube-context "$ctx" upgrade -i istio-base "$ISTIO_HELM_REPO/base" \
    -n "$ISTIO_SYSTEM_NS" --create-namespace --version "$ISTIO_HELM_VERSION" \
    --set defaultRevision=default --wait >/dev/null

  # Values per the documented Solo Istio 1.30.x MANUAL multicluster flow:
  # istiod-native (push-based xDS) peering — DISABLE_LEGACY_MULTICLUSTER ignores
  # community remote secrets; IP autoallocation gives multicluster services VIPs;
  # per-cluster trust domain needs the skip-validate flag.
  helm --kube-context "$ctx" upgrade -i istiod "$ISTIO_HELM_REPO/istiod" \
    -n "$ISTIO_SYSTEM_NS" --version "$ISTIO_HELM_VERSION" --wait -f - >/dev/null <<EOF
profile: ambient
global:
  hub: ${ISTIO_REGISTRY}
  tag: ${ISTIO_VERSION}
  multiCluster:
    clusterName: ${name}
  network: ${name}
  proxy:
    clusterDomain: cluster.local
pilot:
  cni:
    namespace: ${ISTIO_SYSTEM_NS}
    enabled: true
license:
  value: ${SOLO_ISTIO_LICENSE_KEY}
env:
  PILOT_ENABLE_IP_AUTOALLOCATE: "true"
  DISABLE_LEGACY_MULTICLUSTER: "true"
  PILOT_SKIP_VALIDATE_TRUST_DOMAIN: "true"
  PILOT_ENABLE_K8S_SELECT_WORKLOAD_ENTRIES: "false"
platforms:
  peering:
    enabled: true
meshConfig:
  accessLogFile: /dev/stdout
  defaultConfig:
    proxyMetadata:
      ISTIO_META_DNS_CAPTURE: "true"
  # unique per-cluster trust domain: identities are spiffe://${name}/ns/<ns>/sa/<sa>
  # — NOT cluster.local. Part 2 reads this straight off the certificates.
  trustDomain: ${name}
EOF
  kubectl --context "$ctx" -n "$ISTIO_SYSTEM_NS" rollout status deploy/istiod --timeout=180s >/dev/null

  helm --kube-context "$ctx" upgrade -i istio-cni "$ISTIO_HELM_REPO/cni" \
    -n "$ISTIO_SYSTEM_NS" --version "$ISTIO_HELM_VERSION" --wait -f - >/dev/null <<EOF
profile: ambient
global:
  hub: ${ISTIO_REGISTRY}
  tag: ${ISTIO_VERSION}
ambient:
  dnsCapture: true
excludeNamespaces: [istio-system, kube-system]
EOF

  helm --kube-context "$ctx" upgrade -i ztunnel "$ISTIO_HELM_REPO/ztunnel" \
    -n "$ISTIO_SYSTEM_NS" --version "$ISTIO_HELM_VERSION" --wait -f - >/dev/null <<EOF
profile: ambient
hub: ${ISTIO_REGISTRY}
tag: ${ISTIO_VERSION}
namespace: ${ISTIO_SYSTEM_NS}
istioNamespace: ${ISTIO_SYSTEM_NS}
multiCluster:
  clusterName: ${name}
network: ${name}
platforms:
  peering:
    enabled: true
env:
  LOG_FORMAT: json
  L7_ENABLED: "true"
  # required when each cluster has its own trust domain
  SKIP_VALIDATE_TRUST_DOMAIN: "true"
EOF
  kubectl --context "$ctx" -n "$ISTIO_SYSTEM_NS" rollout status ds/ztunnel ds/istio-cni-node --timeout=240s >/dev/null

  kubectl --context "$ctx" label ns "$ISTIO_SYSTEM_NS" \
    "topology.istio.io/network=${name}" --overwrite >/dev/null
  ok "[$name] ambient mesh up (trust domain '${name}', network '${name}')"
}
install_ambient "$CLUSTER1" "$CLUSTER1_NAME"
install_ambient "$CLUSTER2" "$CLUSTER2_NAME"

# ── Step 8: peering — east-west gateways + link ───────────────────────────────
step "East-west gateways: istioctl multicluster expose (both clusters)"
for CTX in "$CLUSTER1" "$CLUSTER2"; do
  kubectl --context "$CTX" create namespace istio-eastwest --dry-run=client -o yaml \
    | kubectl --context "$CTX" apply -f - >/dev/null
  "$ISTIOCTL" --context "$CTX" multicluster expose -n istio-eastwest >/dev/null
  ok "[${CTX#kind-}] east-west gateway exposed"
done

# `link` fails if it runs before the expose-istiod label lands on the services
step "Waiting for the east-west services, then linking the clusters"
for CTX in "$CLUSTER1" "$CLUSTER2"; do
  for _ in $(seq 1 40); do
    [[ -n "$(kubectl --context "$CTX" -n istio-eastwest get svc -l istio.io/expose-istiod -o name 2>/dev/null)" ]] && break
    sleep 3
  done
done
"$ISTIOCTL" multicluster link --namespace istio-eastwest \
  --contexts "$CLUSTER1,$CLUSTER2" >/dev/null
ok "$CLUSTER1_NAME ⇄ $CLUSTER2_NAME linked"

step "Verifying peering (kind cross-cluster convergence can take a few minutes)"
PEERED=no
for _ in $(seq 1 30); do
  if "$ISTIOCTL" --context "$CLUSTER1" multicluster check 2>&1 \
       | grep -q "Peers Check: all clusters connected"; then
    PEERED=yes; break
  fi
  sleep 10
done
[[ "$PEERED" == "yes" ]] && ok "peering verified — both clusters connected" \
  || warn "peering not confirmed yet — cross-cluster traffic may need a minute"

# ── Step 9: Solo Enterprise for agentgateway (both clusters) ──────────────────
# gloo-platform-crds (Gloo UI) and enterprise-agentgateway-crds both ship
# authconfigs + ratelimitconfigs. Helm refuses to adopt CRDs owned by another
# release — hand those two to the agentgateway release first (mesh1 has the
# Gloo CRDs by now; mesh2 gets them at agent registration, hence || true).
step "Solo Enterprise for agentgateway $AGW_VERSION (both clusters)"
for CTX in "$CLUSTER1" "$CLUSTER2"; do
  NAME="${CTX#kind-}"
  for crd in authconfigs.extauth.solo.io ratelimitconfigs.ratelimit.solo.io; do
    owner="$(kubectl --context "$CTX" get crd "$crd" -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null || true)"
    if [[ "$owner" == "gloo-platform-crds" ]]; then
      kubectl --context "$CTX" annotate crd "$crd" \
        meta.helm.sh/release-name=agentgateway-crds \
        meta.helm.sh/release-namespace=agentgateway-system --overwrite >/dev/null
      log "[$NAME] re-annotated $crd → agentgateway-crds"
    fi
  done
  helm --kube-context "$CTX" upgrade -i agentgateway-crds \
    "$AGW_CHARTS/enterprise-agentgateway-crds" \
    -n agentgateway-system --create-namespace --version "$AGW_VERSION" --wait --timeout 3m >/dev/null
  # istio.clusterId/network must match the istiod multiCluster values or
  # mesh-integrated gateways (the waypoint) cannot fetch their certificates.
  helm --kube-context "$CTX" upgrade -i agentgateway \
    "$AGW_CHARTS/enterprise-agentgateway" \
    -n agentgateway-system --version "$AGW_VERSION" \
    --set licensing.licenseKey="$AGENTGATEWAY_LICENSE_KEY" \
    --set istio.clusterId="$NAME" \
    --set istio.network="$NAME" \
    --wait --timeout 5m >/dev/null
  kubectl --context "$CTX" -n agentgateway-system rollout status deploy/enterprise-agentgateway --timeout=120s >/dev/null
  ok "[$NAME] enterprise-agentgateway running (GatewayClasses: enterprise-agentgateway + -waypoint)"
done

# ── Step 10: Keycloak IdP on mesh1 (Part 2 JWT sections) ──────────────────────
step "Keycloak IdP on $CLUSTER1_NAME (realm petshop: alice/user, bob/admin)"
kubectl --context "$CLUSTER1" apply -f "$LAB_ROOT/yaml/40-idp/keycloak.yaml" >/dev/null
ok "Keycloak applied (it finishes booting in the background)"

# ── Step 11: Gloo UI — wait for mesh1, then register mesh2 ────────────────────
if [[ "${SKIP_GLOO_UI:-false}" != "true" ]]; then
  step "Gloo UI: waiting for the background mgmt-plane install"
  for _ in $(seq 1 120); do grep -q "GLOO INSTALL DONE" "$GLOO_LOG" 2>/dev/null && break; sleep 5; done
  grep -q "GLOO INSTALL DONE" "$GLOO_LOG" \
    || { warn "Gloo install has not finished — last lines:"; tail -5 "$GLOO_LOG" >&2; }
  kubectl --context "$CLUSTER1" -n "$GLOO_MESH_NS" rollout status deploy/gloo-mesh-ui --timeout=300s >/dev/null
  ok "Gloo UI up on $CLUSTER1_NAME"

  # Register mesh2 so the service graph spans BOTH clusters. This is a nice-to-
  # have for Part 1 (the cross-cluster hop drawn live) — Part 2 only needs mesh1
  # — so the whole block is NON-FATAL: a failure warns and setup still finishes.
  step "Gloo UI: registering $CLUSTER2_NAME (graph spans both clusters)"
  register_mesh2() {
    set -Eeuo pipefail
    # relay + telemetry endpoints on mesh1's LB IPs
    local RELAY_IP="" TG_IP=""
    for _ in $(seq 1 40); do
      RELAY_IP="$(kubectl --context "$CLUSTER1" -n "$GLOO_MESH_NS" get svc gloo-mesh-mgmt-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
      TG_IP="$(kubectl --context "$CLUSTER1" -n "$GLOO_MESH_NS" get svc gloo-telemetry-gateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
      [[ -n "$RELAY_IP" && -n "$TG_IP" ]] && break
      sleep 3
    done
    [[ -n "$RELAY_IP" ]] || { echo "mgmt-server LB IP not assigned"; return 1; }

    kubectl --context "$CLUSTER1" apply -f - >/dev/null <<REG
apiVersion: admin.gloo.solo.io/v2
kind: KubernetesCluster
metadata: { name: ${CLUSTER2_NAME}, namespace: ${GLOO_MESH_NS} }
spec: { clusterDomain: cluster.local }
REG

    kubectl --context "$CLUSTER2" create namespace "$GLOO_MESH_NS" --dry-run=client -o yaml \
      | kubectl --context "$CLUSTER2" apply -f - >/dev/null

    # CRD-ownership collision: on mesh2 the agentgateway install (Step 9) already
    # owns authconfigs + ratelimitconfigs. Hand them to gloo-platform-crds before
    # its install, or Helm refuses to adopt them.
    for crd in authconfigs.extauth.solo.io ratelimitconfigs.ratelimit.solo.io; do
      kubectl --context "$CLUSTER2" annotate crd "$crd" \
        meta.helm.sh/release-name=gloo-platform-crds \
        meta.helm.sh/release-namespace="$GLOO_MESH_NS" --overwrite >/dev/null 2>&1 || true
      kubectl --context "$CLUSTER2" label crd "$crd" \
        app.kubernetes.io/managed-by=Helm --overwrite >/dev/null 2>&1 || true
    done

    # copy the relay root CA + bootstrap token so the agent can dial the mgmt server
    for s in relay-root-tls-secret relay-identity-token-secret; do
      kubectl --context "$CLUSTER1" -n "$GLOO_MESH_NS" get secret "$s" -o json 2>/dev/null \
        | jq 'del(.metadata.creationTimestamp,.metadata.resourceVersion,.metadata.uid,.metadata.ownerReferences,.metadata.managedFields)' \
        | kubectl --context "$CLUSTER2" apply -f - >/dev/null
    done

    helm --kube-context "$CLUSTER2" upgrade -i gloo-platform-crds gloo-platform/gloo-platform-crds \
      -n "$GLOO_MESH_NS" --version "$GLOO_PLATFORM_VERSION" --wait --timeout 5m >/dev/null
    helm --kube-context "$CLUSTER2" upgrade -i gloo-platform-agent gloo-platform/gloo-platform \
      -n "$GLOO_MESH_NS" --version "$GLOO_PLATFORM_VERSION" -f - >/dev/null <<VALUES
common: { cluster: ${CLUSTER2_NAME} }
glooAgent:
  enabled: true
  relay:
    serverAddress: ${RELAY_IP}:9900
telemetryCollector:
  enabled: true
  config:
    exporters:
      otlp:
        endpoint: ${TG_IP}:4317
VALUES
    echo "relay ${RELAY_IP}:9900  telemetry ${TG_IP}:4317"
  }
  if OUT="$(register_mesh2)"; then
    ok "[$CLUSTER2_NAME] gloo agent installed — graph spans both clusters ($OUT)"
  else
    warn "mesh2 registration skipped ($OUT) — UI shows mesh1 only; Part 1 failover is still provable via curl + browser"
  fi
fi

# ── Step 12: smoke test ───────────────────────────────────────────────────────
step "Smoke test"
FAIL=0
for CTX in "$CLUSTER1" "$CLUSTER2"; do
  NAME="${CTX#kind-}"
  ready="$(kubectl --context "$CTX" -n "$ISTIO_SYSTEM_NS" get ds ztunnel \
            -o jsonpath='{.status.numberReady}/{.status.desiredNumberScheduled}' 2>/dev/null)"
  IFS=/ read -r r d <<< "$ready"
  if [[ -n "$r" && "$r" == "$d" && "${r:-0}" -gt 0 ]]; then
    ok "[$NAME] ztunnel: $ready"
  else
    warn "[$NAME] ztunnel: $ready"; FAIL=1
  fi
  for GC in enterprise-agentgateway enterprise-agentgateway-waypoint; do
    kubectl --context "$CTX" get gatewayclass "$GC" >/dev/null 2>&1 \
      && ok "[$NAME] GatewayClass $GC" || { warn "[$NAME] GatewayClass $GC MISSING"; FAIL=1; }
  done
done
if "$ISTIOCTL" --context "$CLUSTER1" multicluster check 2>&1 \
     | grep -q "Peers Check: all clusters connected"; then
  ok "multicluster peering: connected"
else
  warn "multicluster peering: NOT confirmed"; FAIL=1
fi
kubectl --context "$CLUSTER1" -n keycloak rollout status deploy/keycloak --timeout=600s >/dev/null 2>&1 \
  && ok "Keycloak ready" || { warn "Keycloak not ready yet"; }

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "  Two-part ambient demo — platform is up"
echo "════════════════════════════════════════════════════════════════════"
echo ""
echo "  Clusters:    $CLUSTER1   $CLUSTER2"
echo "  Solo Istio:  $SOLO_ISTIO_VERSION (ambient, plain Helm, peered)"
echo "  agentgateway: $AGW_VERSION (both clusters)"
echo ""
echo "  Consoles:    ./demo-scripts/consoles.sh   (Gloo UI, both clusters)"
echo "  Demo:        open demo.ipynb (Bash kernel) — Part 1 and Part 2 run"
echo "               independently; each starts from this platform."
echo ""
echo "  After a laptop sleep: ./demo-scripts/wake.sh"
echo "  Teardown:            ./setup.sh teardown"
echo ""
[[ "$FAIL" == "0" ]] || { echo "  ⚠ one or more smoke checks failed — see above."; exit 1; }
