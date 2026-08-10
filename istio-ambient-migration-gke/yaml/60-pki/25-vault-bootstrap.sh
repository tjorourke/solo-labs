#!/usr/bin/env bash
# 25-vault-bootstrap.sh — RSA root, RSA intermediate, an RSA-only signing role,
# and the Kubernetes auth role the cert-manager Issuer uses. Run once, after the
# Vault chart is up and before istio-csr is installed.
#
# This models the estate you are migrating rather than a greenfield one: a
# long-standing RSA PKI, where nothing has ever had to sign an EC key because
# sidecars only ever asked for RSA. Ambient is what changes that.
#
# Everything runs through `kubectl exec` into vault-0, so no local vault CLI is
# needed. Dev-mode Vault, root token, lab only.
set -euo pipefail

ISTIO_NS="${ISTIO_NS:-istio-system}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

v() { kubectl -n vault exec vault-0 -- sh -c "VAULT_TOKEN=root VAULT_ADDR=http://127.0.0.1:8200 $*"; }

echo "==> root CA: RSA-4096, CN='Lab Root CA'"
v "vault secrets enable pki" >/dev/null 2>&1 || true
v "vault secrets tune -max-lease-ttl=87600h pki" >/dev/null
v "vault write -field=certificate pki/root/generate/internal \
     common_name='Lab Root CA' key_type=rsa key_bits=4096 ttl=87600h" >/dev/null

echo "==> intermediate CA: RSA-4096, CN='Lab Intermediate CA', signed by the root"
v "vault secrets enable -path=pki_int pki" >/dev/null 2>&1 || true
v "vault secrets tune -max-lease-ttl=43800h pki_int" >/dev/null
CSR="$(v "vault write -field=csr pki_int/intermediate/generate/internal \
           common_name='Lab Intermediate CA' key_type=rsa key_bits=4096")"
SIGNED="$(printf '%s' "$CSR" | kubectl -n vault exec -i vault-0 -- sh -c \
  "VAULT_TOKEN=root VAULT_ADDR=http://127.0.0.1:8200 vault write -field=certificate \
     pki/root/sign-intermediate csr=- format=pem_bundle ttl=43800h")"
printf '%s' "$SIGNED" | kubectl -n vault exec -i vault-0 -- sh -c \
  "VAULT_TOKEN=root VAULT_ADDR=http://127.0.0.1:8200 vault write pki_int/intermediate/set-signed certificate=-" >/dev/null

echo "==> signing role, locked to RSA (the posture that will reject ztunnel)"
"$SCRIPT_DIR/30-vault-role.sh" rsa

echo "==> Kubernetes auth for the cert-manager Issuer"
v "vault auth enable kubernetes" >/dev/null 2>&1 || true
v "vault write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc" >/dev/null

# The policy is deliberately one path. Relaxing the role's key type later is
# bounded to this signing path, not to the CA.
kubectl -n vault exec -i vault-0 -- sh -c \
  "VAULT_TOKEN=root VAULT_ADDR=http://127.0.0.1:8200 vault policy write istio-ca -" >/dev/null <<'EOF'
path "pki_int/sign/istio-ca" {
  capabilities = ["create", "update"]
}
EOF

# cert-manager's serviceAccountRef flow mints tokens with the audience
# vault://<issuer-namespace>/<issuer-name>, so the Vault role has to match it.
v "vault write auth/kubernetes/role/vault-issuer \
     bound_service_account_names=vault-issuer \
     bound_service_account_namespaces=$ISTIO_NS \
     audience='vault://$ISTIO_NS/istio-ca' \
     policies=istio-ca ttl=10m" >/dev/null

echo "==> done. istio-csr can now be installed against Issuer istio-ca in $ISTIO_NS."

# The root certificate istio-csr needs as its trust anchor:
#   kubectl -n vault exec vault-0 -- sh -c \
#     'VAULT_TOKEN=root VAULT_ADDR=http://127.0.0.1:8200 vault read -field=certificate pki/cert/ca' \
#     > ca.pem
#   kubectl -n cert-manager create secret generic istio-root-ca --from-file=ca.pem=ca.pem
