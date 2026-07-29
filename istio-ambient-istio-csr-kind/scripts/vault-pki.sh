#!/usr/bin/env bash
# vault-pki.sh — Vault PKI for the mesh CA, driven entirely through
# `kubectl exec` into vault-0 (no local vault CLI needed).
#
#   ./scripts/vault-pki.sh bootstrap     # root + intermediate + role (RSA-only) + k8s auth
#   ./scripts/vault-pki.sh role rsa      # role signs RSA CSRs only  (the starting posture)
#   ./scripts/vault-pki.sh role any      # role signs RSA and EC     (the migration posture)
#   ./scripts/vault-pki.sh role ec       # role signs EC only        (the trap — breaks sidecars)
#   ./scripts/vault-pki.sh show          # current role key_type + issuance counters
#
# The PKI mirrors a bank that standardised on RSA: RSA-4096 root, RSA-4096
# intermediate, and a signing role locked to key_type=rsa key_bits=2048.
# Sidecars (istio-agent) send RSA-2048 CSRs, so nothing notices — until
# ztunnel, which only generates ECDSA P-256 keys, asks for its first cert.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

# Everything except key_type/key_bits is identical for every role posture, and
# `vault write` on a role REPLACES it, so always write the full parameter set.
write_role() { # write_role <rsa|any|ec>
  local kt="$1" bits=()
  [[ "$kt" == "rsa" ]] && bits=(key_bits=2048)
  vexec write pki_int/roles/istio-ca \
    allowed_uri_sans="spiffe://*" \
    allow_any_name=true \
    enforce_hostnames=false \
    require_cn=false \
    server_flag=true \
    client_flag=true \
    key_type="$kt" ${bits[@]+"${bits[@]}"} \
    ttl=1h max_ttl=24h >/dev/null
  ok "Vault role pki_int/roles/istio-ca now key_type=$kt"
}

bootstrap() {
  step "Vault PKI: RSA root + RSA intermediate + RSA-only signing role"

  if vexec secrets list -format=json | jq -e '."pki/"' >/dev/null 2>&1; then
    ok "PKI already mounted — skipping mount + CA generation"
  else
    vexec secrets enable pki >/dev/null
    vexec secrets tune -max-lease-ttl=87600h pki >/dev/null
    vexec write -field=certificate pki/root/generate/internal \
      common_name="Lab Root CA" key_type=rsa key_bits=4096 ttl=87600h >/dev/null
    ok "root CA: RSA-4096, CN='Lab Root CA' (10y)"

    vexec secrets enable -path=pki_int pki >/dev/null
    vexec secrets tune -max-lease-ttl=43800h pki_int >/dev/null
    local csr signed
    csr="$(vexec write -field=csr pki_int/intermediate/generate/internal \
      common_name="Lab Intermediate CA" key_type=rsa key_bits=4096)"
    signed="$(printf '%s' "$csr" | vexec write -field=certificate \
      pki/root/sign-intermediate csr=- format=pem_bundle ttl=43800h)"
    printf '%s' "$signed" | vexec write pki_int/intermediate/set-signed certificate=- >/dev/null
    ok "intermediate CA: RSA-4096, CN='Lab Intermediate CA' (5y), signed by the root"
  fi

  write_role rsa

  step "Vault Kubernetes auth for the cert-manager Issuer"
  if vexec auth list -format=json | jq -e '."kubernetes/"' >/dev/null 2>&1; then
    ok "kubernetes auth already enabled"
  else
    vexec auth enable kubernetes >/dev/null
  fi
  vexec write auth/kubernetes/config \
    kubernetes_host="https://kubernetes.default.svc" >/dev/null
  vexec policy write istio-ca - >/dev/null <<'EOF'
path "pki_int/sign/istio-ca" {
  capabilities = ["create", "update"]
}
EOF
  # cert-manager's serviceAccountRef flow mints tokens with the audience
  # vault://<issuer-namespace>/<issuer-name>; the Vault role must match it.
  vexec write auth/kubernetes/role/vault-issuer \
    bound_service_account_names=vault-issuer \
    bound_service_account_namespaces="$ISTIO_SYSTEM_NS" \
    audience="vault://${ISTIO_SYSTEM_NS}/istio-ca" \
    policies=istio-ca ttl=10m >/dev/null
  ok "auth role 'vault-issuer' bound to sa/${ISTIO_SYSTEM_NS}/vault-issuer, policy allows pki_int/sign/istio-ca only"
}

show() {
  printf 'role key_type: %s\n' "$(vexec read -field=key_type pki_int/roles/istio-ca)"
  printf 'role key_bits: %s\n' "$(vexec read -field=key_bits pki_int/roles/istio-ca || true)"
}

case "${1:-}" in
  bootstrap) bootstrap ;;
  role)
    case "${2:-}" in
      rsa|any|ec) write_role "$2" ;;
      *) die "usage: vault-pki.sh role <rsa|any|ec>" ;;
    esac ;;
  show) show ;;
  *) die "usage: vault-pki.sh <bootstrap|role rsa|any|ec|show>" ;;
esac
