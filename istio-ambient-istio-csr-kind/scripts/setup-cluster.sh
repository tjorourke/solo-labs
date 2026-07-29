#!/usr/bin/env bash
# setup-cluster.sh — stands up the RSA starting posture, end to end:
#
#   1. kind cluster (1 control-plane + 1 worker) + Gateway API CRDs
#   2. Istio images pre-pulled on the host and kind-loaded
#   3. cert-manager
#   4. Vault (dev mode) + an all-RSA PKI: RSA-4096 root, RSA-4096 intermediate,
#      signing role locked to key_type=rsa key_bits=2048
#   5. cert-manager Vault Issuer (kubernetes auth, no stored Vault token)
#   6. istio-csr (v0.16.0) — istiod cert and its own serving cert are RSA too
#   7. Istio in SIDECAR mode: istiod with its built-in CA disabled and
#      caAddress pointed at istio-csr
#
# Nothing ambient yet — that arrives later (scripts/ambient-enable.sh), which
# is the whole point: this is the mesh a long-standing RSA estate runs today.
# Idempotent. Needs docker, kind, kubectl, helm, jq. Everything is upstream
# OSS — no licence, no registry auth.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

require kind; require kubectl; require helm; require docker; require jq
check_docker

step "Creating kind cluster '$CLUSTER_NAME'"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  ok "cluster '$CLUSTER_NAME' already exists"
else
  kind create cluster --config "$LAB_ROOT/kind/cluster.yaml" >/dev/null
  ok "cluster '$CLUSTER_NAME' created"
fi
kc wait --for=condition=Ready nodes --all --timeout=120s >/dev/null

step "Installing Gateway API CRDs $GATEWAY_API_VERSION"
kc apply --server-side -f \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" >/dev/null
ok "Gateway API CRDs installed"

step "Pre-pulling Istio images ($ISTIO_VERSION, upstream OSS) and loading into kind"
__tar_tmp="$(mktemp -d)"; trap 'rm -rf "$__tar_tmp"' EXIT
while read -r img; do
  docker image inspect "$img" >/dev/null 2>&1 || { log "pulling $img …"; docker pull --quiet "$img" >/dev/null; }
  tar="$__tar_tmp/$(echo "$img" | tr '/:' '__').tar"
  docker save --platform "$KIND_PLATFORM" "$img" -o "$tar"
  log "loading $(basename "$img") into kind …"
  kind load image-archive "$tar" --name "$CLUSTER_NAME" >/dev/null
  rm -f "$tar"
done < <(istio_images)
ok "Istio images loaded"

step "Helm: cert-manager $CERT_MANAGER_VERSION"
helm --kube-context "$CTX" upgrade -i cert-manager cert-manager \
  --repo https://charts.jetstack.io \
  -n "$CM_NS" --create-namespace --version "$CERT_MANAGER_VERSION" \
  --set crds.enabled=true --wait >/dev/null
ok "cert-manager ready"

step "Helm: Vault $VAULT_CHART_VERSION (dev mode, in-memory, root token 'root')"
helm --kube-context "$CTX" upgrade -i vault vault \
  --repo https://helm.releases.hashicorp.com \
  -n "$VAULT_NS" --create-namespace --version "$VAULT_CHART_VERSION" \
  --set server.dev.enabled=true \
  --set server.dev.devRootToken=root \
  --set injector.enabled=false --wait >/dev/null
kc -n "$VAULT_NS" wait --for=condition=Ready pod/vault-0 --timeout=180s >/dev/null
ok "Vault running (dev mode — fine for a lab, never for production)"

"$SCRIPT_DIR/vault-pki.sh" bootstrap

step "Publishing the Vault ROOT CA to istio-csr (secret istio-root-ca)"
__root_ca="$(mktemp)"
vexec read -field=certificate pki/cert/ca > "$__root_ca"
kc -n "$CM_NS" create secret generic istio-root-ca \
  --from-file=ca.pem="$__root_ca" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
rm -f "$__root_ca"
ok "root CA published — istio-csr will distribute it as the mesh trust anchor"

step "cert-manager Vault Issuer (kubernetes auth, audience-scoped token)"
kapply "$LAB_ROOT/yaml/00-pki/vault-issuer.yaml"
ok "Issuer istio-ca -> vault pki_int/sign/istio-ca"

step "Helm: istio-csr $ISTIO_CSR_VERSION (readiness gates on the Vault Issuer working)"
helm --kube-context "$CTX" upgrade -i cert-manager-istio-csr cert-manager-istio-csr \
  --repo https://charts.jetstack.io \
  -n "$CM_NS" --version "$ISTIO_CSR_VERSION" --wait -f - >/dev/null <<EOF
replicaCount: 1
app:
  logLevel: 2
  certmanager:
    namespace: ${ISTIO_SYSTEM_NS}
    # keep every CertificateRequest around: the audit trail of exactly what
    # was signed (and, later, what Vault refused and why)
    preserveCertificateRequests: true
    issuer:
      name: istio-ca
      kind: Issuer
      group: cert-manager.io
  tls:
    trustDomain: cluster.local
    # the Vault ROOT CA — served to workloads as the mesh trust anchor
    rootCAFile: /var/run/secrets/istio-csr/ca.pem
    certificateDNSNames:
      - cert-manager-istio-csr.${CM_NS}.svc
  server:
    clusterID: Kubernetes
  istio:
    revisions: ["default"]
volumeMounts:
  - name: root-ca
    mountPath: /var/run/secrets/istio-csr
volumes:
  - name: root-ca
    secret:
      secretName: istio-root-ca
EOF
kc -n "$ISTIO_SYSTEM_NS" wait --for=jsonpath='{.type}'=kubernetes.io/tls \
  secret/istiod-tls --timeout=120s >/dev/null 2>&1 || \
  kc -n "$ISTIO_SYSTEM_NS" get secret istiod-tls >/dev/null
ok "istio-csr ready; istiod-tls (RSA) issued through Vault"

HVER="$ISTIO_HELM_VERSION"

step "Helm: istio-base (CRDs)"
# shellcheck disable=SC2046
helm --kube-context "$CTX" upgrade -i istio-base $(helm_chart base) \
  -n "$ISTIO_SYSTEM_NS" --version "$HVER" \
  --set defaultRevision=default --wait >/dev/null
ok "istio-base installed"

step "Helm: istiod (SIDECAR mode) — built-in CA off, caAddress -> istio-csr"
# shellcheck disable=SC2046
helm --kube-context "$CTX" upgrade -i istiod $(helm_chart istiod) \
  -n "$ISTIO_SYSTEM_NS" --version "$HVER" --wait -f - >/dev/null <<EOF
global:
  hub: ${ISTIO_REGISTRY}
  tag: ${ISTIO_VERSION}
  # every proxy asks istio-csr (not istiod) for its certificate
  caAddress: cert-manager-istio-csr.${CM_NS}.svc:443
pilot:
  env:
    # istiod no longer signs anything — Vault is the only CA in this mesh
    ENABLE_CA_SERVER: "false"
meshConfig:
  accessLogFile: /dev/stdout
EOF
kc -n "$ISTIO_SYSTEM_NS" rollout status deploy/istiod --timeout=180s >/dev/null
ok "istiod ready (sidecar mode), CA duties delegated to istio-csr -> Vault"

echo
ok "RSA baseline up: Istio $ISTIO_VERSION (upstream OSS), CA = Vault (RSA root/intermediate, role key_type=rsa)."
log "Next: kubectl apply -f yaml/10-apps/ then follow the README."
