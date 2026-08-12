#!/usr/bin/env bash
# Vault as a production-grade mesh CA: raft storage, KMS auto-unseal, TLS listener.
#
#   ./scripts/vault.sh up        KMS + IRSA check, raft install, init, PKI bootstrap
#   ./scripts/vault.sh pki       (re)build the PKI mounts, role and k8s auth
#   ./scripts/vault.sh status     seal state, storage type, raft peers, PKI role
#   ./scripts/vault.sh unseal-test  kill the pod and prove it comes back unsealed
#   ./scripts/vault.sh down      remove Vault (leaves the KMS key and IAM alone)
#
# WHY NOT DEV MODE. A dev-mode Vault is in-memory and unsealed with a root token of
# "root". It demonstrates the architecture but it is not a root of trust, and on a page
# about security a sharp reader will say so. Worse operationally: if the pod restarts,
# the PKI mount is gone, istio-csr cannot sign, and nothing appears to break until the
# first certificate renewal an hour later.
#
# WHY KMS AUTO-UNSEAL AND NOT SHAMIR. Raft alone fixes durability and leaves the harder
# problem: a restarted Vault comes back SEALED and waits for a human to paste unseal
# keys. That turns any pod eviction into a PKI outage on a one hour fuse. With
# seal "awskms", Vault unseals itself from a KMS key, so a restart is a non-event.
#
# It also sharpens the sovereignty claim rather than muddying it: the key that unseals
# the PKI is a KMS key in eu-west-2, owned by this account, and the IAM policy on it
# allows exactly Encrypt, Decrypt and DescribeKey on that one key ARN and nothing else.
# Vault reaches it with an IRSA role, so there is no AWS credential in the cluster.
set -euo pipefail

export AWS_PROFILE="${SOVEREIGN_AWS_PROFILE:?set SOVEREIGN_AWS_PROFILE to the sandbox SSO profile}"
REGION=eu-west-2
CLUSTER=uk-sovereign-ai
VAULT_NS=vault
CM_NS=cert-manager
ISTIO_NS=istio-system
VAULT_CHART_VERSION="${VAULT_CHART_VERSION:-0.34.0}"
KMS_ALIAS="alias/uk-sovereign-ai-vault-unseal"

ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
[ -n "$ACCOUNT" ] && [ "$ACCOUNT" != "None" ] || { echo "error: no AWS identity; check SOVEREIGN_AWS_PROFILE" >&2; exit 1; }
CTX="arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${CLUSTER}"
kc() { command kubectl --context "$CTX" "$@"; }
helm_() { command helm --kube-context "$CTX" "$@"; }

# The init material lives OUTSIDE the repo. With KMS auto-unseal these are RECOVERY
# keys, not unseal keys: Vault does not need them to start, only to recover if the KMS
# key is lost or to regenerate a root token. Treat them like a break-glass envelope.
INIT_FILE="${VAULT_INIT_FILE:-$HOME/.solo-sovereign-vault-init.json}"

# Every Vault command runs through kubectl exec, so no local vault CLI is needed. Once
# TLS is on, the CLI inside the pod must be told to trust the CA it is talking to.
vexec() {
  kc -n "$VAULT_NS" exec -i vault-0 -- env \
    VAULT_ADDR=https://127.0.0.1:8200 \
    VAULT_CACERT=/vault/userconfig/vault-tls/ca.crt \
    VAULT_TOKEN="$(root_token)" vault "$@"
}
# Before init there is no token, and vault status must work without one.
vstatus() {
  kc -n "$VAULT_NS" exec -i vault-0 -- env \
    VAULT_ADDR=https://127.0.0.1:8200 \
    VAULT_CACERT=/vault/userconfig/vault-tls/ca.crt vault status "$@" 2>/dev/null
}
root_token() { [ -f "$INIT_FILE" ] && python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["root_token"])' "$INIT_FILE" 2>/dev/null || echo ""; }

kms_key_id() {
  aws kms list-aliases --region "$REGION" \
    --query "Aliases[?AliasName=='${KMS_ALIAS}'].TargetKeyId" --output text 2>/dev/null
}

# Vault's own serving certificate comes from a cert-manager SelfSigned CA that has
# NOTHING to do with the mesh PKI. That separation is what avoids a circular
# dependency: the mesh CA lives in Vault, so Vault's TLS cannot be issued by the mesh CA.
vault_tls() {
  echo "==> Vault TLS from a dedicated self-signed CA (kept separate from the mesh PKI)"
  kc apply -f - >/dev/null <<'TLS'
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: vault-selfsign
  namespace: vault
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: vault-ca
  namespace: vault
spec:
  isCA: true
  commonName: Vault Internal CA
  secretName: vault-ca
  privateKey: {algorithm: RSA, size: 4096}
  issuerRef: {name: vault-selfsign, kind: Issuer, group: cert-manager.io}
---
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: vault-ca
  namespace: vault
spec:
  ca:
    secretName: vault-ca
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: vault-tls
  namespace: vault
spec:
  secretName: vault-tls
  commonName: vault.vault.svc
  dnsNames:
    - vault
    - vault.vault
    - vault.vault.svc
    - vault.vault.svc.cluster.local
    - vault-0.vault-internal
    - localhost
  ipAddresses: ["127.0.0.1"]
  privateKey: {algorithm: RSA, size: 2048}
  issuerRef: {name: vault-ca, kind: Issuer, group: cert-manager.io}
TLS
  kc -n "$VAULT_NS" wait --for=condition=Ready certificate/vault-tls --timeout=180s >/dev/null
  # The chart mounts the secret at /vault/userconfig/<secretName>, and Vault's config
  # references tls.crt / tls.key / ca.crt from there.
  echo "    ok"
}

pki() {
  local tok; tok="$(root_token)"
  [ -n "$tok" ] || { echo "error: no root token in $INIT_FILE; run '$0 up' first" >&2; exit 1; }

  echo "==> PKI: root + intermediate"
  if vexec secrets list -format=json 2>/dev/null | grep -q '"pki/"'; then
    echo "    already mounted, skipping CA generation"
  else
    vexec secrets enable pki >/dev/null
    vexec secrets tune -max-lease-ttl=87600h pki >/dev/null
    vexec write -field=certificate pki/root/generate/internal \
      common_name="UK Sovereign AI Root CA" key_type=rsa key_bits=4096 ttl=87600h >/dev/null
    vexec secrets enable -path=pki_int pki >/dev/null
    vexec secrets tune -max-lease-ttl=43800h pki_int >/dev/null
    local csr signed
    csr="$(vexec write -field=csr pki_int/intermediate/generate/internal \
      common_name="UK Sovereign AI Intermediate CA" key_type=rsa key_bits=4096)"
    signed="$(printf '%s' "$csr" | vexec write -field=certificate \
      pki/root/sign-intermediate csr=- format=pem_bundle ttl=43800h)"
    printf '%s' "$signed" | vexec write pki_int/intermediate/set-signed certificate=- >/dev/null
    echo "    root + intermediate created (RSA-4096)"
  fi

  # key_type=any: the CLIENT picks the key type. ztunnel only generates ECDSA P-256,
  # istiod's own serving cert arrives as RSA. A role locked to either refuses one of
  # them and the mesh looks healthy until something needs a new certificate.
  # A role write REPLACES the role, so write the full parameter set every time.
  echo "==> signing role (key_type=any: ztunnel is EC, istiod-tls is RSA)"
  vexec write pki_int/roles/istio-ca \
    allowed_uri_sans="spiffe://*" allow_any_name=true enforce_hostnames=false \
    require_cn=false server_flag=true client_flag=true \
    key_type=any ttl=1h max_ttl=24h >/dev/null
  echo "    ok, 1h certs with a 24h ceiling"

  echo "==> Kubernetes auth (no long-lived Vault token in the cluster)"
  vexec auth list -format=json 2>/dev/null | grep -q '"kubernetes/"' || vexec auth enable kubernetes >/dev/null
  vexec write auth/kubernetes/config kubernetes_host="https://kubernetes.default.svc" >/dev/null
  vexec policy write istio-ca - >/dev/null <<'POLICY'
path "pki_int/sign/istio-ca" {
  capabilities = ["create", "update"]
}
POLICY
  # The audience MUST equal vault://<issuer-ns>/<issuer-name>, because that is what
  # cert-manager mints its ServiceAccount token for. A mismatch is a permission denied
  # that reads like a policy bug.
  vexec write auth/kubernetes/role/vault-issuer \
    bound_service_account_names=vault-issuer \
    bound_service_account_namespaces="$ISTIO_NS" \
    audience="vault://${ISTIO_NS}/istio-ca" \
    policies=istio-ca ttl=10m >/dev/null
  echo "    ok, policy allows pki_int/sign/istio-ca only"

  echo "==> publishing the root CA as the mesh trust anchor"
  local root_ca; root_ca="$(mktemp)"
  vexec read -field=certificate pki/cert/ca > "$root_ca"
  kc -n "$CM_NS" create secret generic istio-root-ca --from-file=ca.pem="$root_ca" \
    --dry-run=client -o yaml | kc apply -f - >/dev/null
  rm -f "$root_ca"
  echo "    ok"

  # The Issuer lives here rather than in istio-csr.sh because only this script knows
  # whether Vault is serving TLS and which CA signed its certificate. Getting that wrong
  # is not a small error: an http:// Issuer against a TLS listener fails with
  # "connection reset by peer" from cert-manager, every CertificateRequest stalls
  # unsigned, and the visible symptom is istio-csr never going ready plus ztunnel
  # logging "invalid peer certificate: BadSignature". None of that points at a URL.
  echo "==> cert-manager Issuer fronting Vault over TLS"
  local ca_b64
  ca_b64="$(kc -n "$VAULT_NS" get secret vault-tls -o jsonpath='{.data.ca\.crt}' 2>/dev/null)"
  [ -n "$ca_b64" ] || { echo "error: no ca.crt in secret vault-tls" >&2; exit 1; }
  kc apply -f - >/dev/null <<ISSUER
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vault-issuer
  namespace: ${ISTIO_NS}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: vault-issuer-token
  namespace: ${ISTIO_NS}
rules:
  - apiGroups: [""]
    resources: ["serviceaccounts/token"]
    resourceNames: ["vault-issuer"]
    verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: vault-issuer-token
  namespace: ${ISTIO_NS}
subjects:
  - kind: ServiceAccount
    name: cert-manager
    namespace: ${CM_NS}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: vault-issuer-token
---
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: istio-ca
  namespace: ${ISTIO_NS}
spec:
  vault:
    server: https://vault.${VAULT_NS}.svc:8200
    caBundle: ${ca_b64}
    path: pki_int/sign/istio-ca
    auth:
      kubernetes:
        mountPath: /v1/auth/kubernetes
        role: vault-issuer
        serviceAccountRef:
          name: vault-issuer
ISSUER
  echo "    ok, https with the Vault internal CA pinned"

  # Rotating the CA leaves istiod holding a serving cert signed by the OLD intermediate,
  # and BOTH CAs have the identical CN, so you cannot tell them apart by name, only by
  # notBefore. ztunnel then fails with "invalid peer certificate: BadSignature" against
  # istiod:15012 and no ztunnel pod reaches ready. Deleting the secret makes istio-csr
  # re-issue from the current Vault.
  echo "==> forcing istiod-tls re-issue from the current Vault"
  kc -n "$ISTIO_NS" delete secret istiod-tls >/dev/null 2>&1 || true
  kc -n "$CM_NS" get deploy cert-manager-istio-csr >/dev/null 2>&1 && {
    kc -n "$CM_NS" rollout restart deploy/cert-manager-istio-csr >/dev/null
    kc -n "$CM_NS" rollout status deploy/cert-manager-istio-csr --timeout=240s >/dev/null 2>&1 || true
    kc -n "$ISTIO_NS" rollout restart deploy/istiod >/dev/null 2>&1 || true
    kc -n "$ISTIO_NS" rollout status deploy/istiod --timeout=300s >/dev/null 2>&1 || true
    # Delete rather than rollout restart: a DaemonSet rollout will not replace a pod
    # whose new revision cannot pass readiness, so it sits at "0 out of N updated".
    kc -n "$ISTIO_NS" delete pods -l app=ztunnel --wait=false >/dev/null 2>&1 || true
    echo "    istiod-tls re-issued, istiod and ztunnel rolled"
  } || echo "    (istio-csr not installed yet, nothing to roll)"
}

case "${1:-status}" in
  up)
    KEY_ID="$(kms_key_id)"
    [ -n "$KEY_ID" ] && [ "$KEY_ID" != "None" ] || {
      echo "error: KMS alias $KMS_ALIAS not found. Create the key and IAM policy first." >&2; exit 1; }
    echo "==> KMS unseal key: $KEY_ID ($KMS_ALIAS, $REGION)"

    ROLE="$(kc -n "$VAULT_NS" get sa vault -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || echo '')"
    [ -n "$ROLE" ] || { echo "error: sa/vault has no IRSA role annotation" >&2; exit 1; }
    echo "==> Vault will assume $ROLE (no AWS credential in the cluster)"

    # cert-manager must exist before Vault, because Vault's TLS cert comes from it. Vault
    # is the first thing in the run order that needs cert-manager, so it installs it here
    # rather than depending on istio-csr.sh having run first. istio-csr.sh is idempotent
    # and will find it already present.
    if ! kc -n "$CM_NS" get deploy cert-manager >/dev/null 2>&1; then
      echo "==> cert-manager ${CERT_MANAGER_VERSION:-v1.21.1} (needed for the Vault TLS cert)"
      helm_ upgrade -i cert-manager cert-manager --repo https://charts.jetstack.io \
        -n "$CM_NS" --create-namespace --version "${CERT_MANAGER_VERSION:-v1.21.1}" \
        --set crds.enabled=true --wait >/dev/null
      echo "    installed"
    fi
    vault_tls

    echo "==> Vault $VAULT_CHART_VERSION: raft storage, KMS auto-unseal, TLS"
    # serviceAccount.create=false: the SA already exists with the IRSA annotation, and
    # letting the chart recreate it would drop the annotation and break auto-unseal with
    # a 403 from KMS that surfaces as "Vault is sealed".
    helm_ upgrade -i vault vault --repo https://helm.releases.hashicorp.com \
      -n "$VAULT_NS" --create-namespace --version "$VAULT_CHART_VERSION" \
      --wait --timeout 10m -f - >/dev/null <<EOF
injector:
  enabled: false
global:
  # tlsDisable: false is what makes the chart set VAULT_ADDR to https and point its
  # readiness probe at https. Do NOT also set VAULT_ADDR in extraEnvironmentVars: the
  # chart already defines it, and a second copy fails the install with "duplicate
  # entries for key [name=\"VAULT_ADDR\"]" from server-side apply, which reads like a
  # Kubernetes problem rather than a values mistake.
  tlsDisable: false
server:
  serviceAccount:
    create: false
    name: vault
  dataStorage:
    enabled: true
    size: 10Gi
    storageClass: gp3
  volumes:
    - name: vault-tls
      secret:
        secretName: vault-tls
  volumeMounts:
    - name: vault-tls
      mountPath: /vault/userconfig/vault-tls
      readOnly: true
  extraEnvironmentVars:
    # VAULT_ADDR is deliberately absent, see the global.tlsDisable comment above.
    VAULT_CACERT: /vault/userconfig/vault-tls/ca.crt
    AWS_REGION: ${REGION}
  ha:
    enabled: true
    replicas: 1
    raft:
      enabled: true
      setNodeId: true
      config: |
        ui = true
        listener "tcp" {
          address = "[::]:8200"
          cluster_address = "[::]:8201"
          tls_cert_file = "/vault/userconfig/vault-tls/tls.crt"
          tls_key_file  = "/vault/userconfig/vault-tls/tls.key"
          tls_client_ca_file = "/vault/userconfig/vault-tls/ca.crt"
        }
        storage "raft" {
          path = "/vault/data"
        }
        # Auto-unseal. Vault reaches KMS with the IRSA role on sa/vault, so there is no
        # access key anywhere, and the policy on the role permits three actions on one
        # key ARN.
        seal "awskms" {
          region     = "${REGION}"
          kms_key_id = "${KEY_ID}"
        }
        service_registration "kubernetes" {}
EOF
    echo "    chart installed"

    echo "==> waiting for vault-0 to start (it will be uninitialised at first)"
    for _ in $(seq 1 40); do
      kc -n "$VAULT_NS" get pod vault-0 >/dev/null 2>&1 && break; sleep 5
    done
    for _ in $(seq 1 60); do
      vstatus >/dev/null 2>&1 && break
      kc -n "$VAULT_NS" get pod vault-0 -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Running && break
      sleep 5
    done

    if vstatus | grep -qE 'Initialized.*true'; then
      echo "    already initialised"
    else
      echo "==> initialising (KMS auto-unseal, so these are RECOVERY keys not unseal keys)"
      kc -n "$VAULT_NS" exec -i vault-0 -- env \
        VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/vault/userconfig/vault-tls/ca.crt \
        vault operator init -recovery-shares=5 -recovery-threshold=3 -format=json > "$INIT_FILE"
      chmod 600 "$INIT_FILE"
      echo "    recovery keys + root token written to $INIT_FILE (mode 600, OUTSIDE the repo)"
    fi

    echo "==> seal state after init"
    vstatus | grep -E 'Seal Type|Initialized|Sealed|Storage Type|Recovery' | sed 's/^/    /'

    pki
    echo
    echo "Vault is raft-backed and auto-unsealing from KMS in ${REGION}."
    echo "Next: point istio-csr at it (./scripts/istio-csr.sh up) then verify:"
    echo "  ./scripts/vault.sh unseal-test    # prove a restart does not wedge the PKI"
    ;;

  pki) pki ;;

  unseal-test)
    # The whole point of KMS auto-unseal, proven rather than asserted. On Shamir this
    # test leaves Vault sealed and the mesh on a one hour fuse.
    echo "=== before"
    vstatus | grep -E 'Sealed|Storage Type' | sed 's/^/  /'
    echo "=== deleting vault-0"
    kc -n "$VAULT_NS" delete pod vault-0 --wait=false >/dev/null
    sleep 10
    for _ in $(seq 1 60); do
      s="$(vstatus | grep -E '^Sealed' | awk '{print $2}')" || true
      [ "$s" = "false" ] && { echo "=== after: came back UNSEALED with no human involved"; break; }
      sleep 5
    done
    vstatus | grep -E 'Seal Type|Initialized|Sealed|Storage Type' | sed 's/^/  /'
    echo "=== PKI still signing?"
    vexec read -field=key_type pki_int/roles/istio-ca 2>/dev/null | sed 's/^/  role key_type: /' \
      || echo "  PKI unreachable"
    ;;

  status)
    echo "=== pods"
    kc -n "$VAULT_NS" get pods --no-headers 2>/dev/null || echo "  not installed"
    echo
    echo "=== seal + storage"
    vstatus | grep -E 'Seal Type|Initialized|Sealed|Storage Type|Version|HA Mode' | sed 's/^/  /' || echo "  unreachable"
    echo
    echo "=== raft peers"
    vexec operator raft list-peers 2>/dev/null | sed 's/^/  /' || echo "  (needs a root token)"
    echo
    echo "=== PKI signing role"
    vexec read -field=key_type pki_int/roles/istio-ca 2>/dev/null | sed 's/^/  key_type: /' || echo "  no PKI"
    echo
    echo "=== unseal key (KMS, eu-west-2)"
    echo "  $KMS_ALIAS -> $(kms_key_id)"
    ;;

  down)
    echo "This removes Vault. The KMS key and IAM policy are left alone."
    read -r -p "type 'yes' to continue: " a
    [ "$a" = "yes" ] || exit 1
    helm_ uninstall vault -n "$VAULT_NS" >/dev/null 2>&1 || true
    # The raft PVC survives a helm uninstall, which is usually what you want and is
    # also how a "fresh" reinstall silently keeps the old PKI.
    echo "removed. The raft PVC remains:"
    kc -n "$VAULT_NS" get pvc 2>/dev/null | sed 's/^/  /'
    ;;

  *) echo "usage: $0 {up|pki|status|unseal-test|down}"; exit 1 ;;
esac
