#!/usr/bin/env bash
# 03-pki.sh — the three certificate authorities this lab needs, and the
# Kubernetes objects agentgateway reads them from.
#
#   upstream-ca   stands in for a public CA. Signs the destination API's
#                 certificate. This is what a gateway with no corporate proxy
#                 in the path would already trust.
#   corp-ca       the corporate inspection CA. mitmproxy re-signs every
#                 destination certificate with it, which is exactly why
#                 verification against upstream-ca starts failing.
#   proxy leaf    the TLS front door on the proxy itself, signed by corp-ca.
#
# Nothing here is precious. Delete .pki and re-run to rotate the lot.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require openssl

mkdir -p "$PKI_DIR"
cd "$PKI_DIR"

# make_ca <slug> <common name>
make_ca() {
  local slug="$1" cn="$2"
  if [[ -f "${slug}.crt" && -f "${slug}.key" ]]; then
    log "reusing ${slug}.crt"
    return 0
  fi
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "${slug}.key" -out "${slug}.crt" \
    -subj "/CN=${cn}" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1
  ok "CA ${slug} (${cn})"
}

# make_leaf <slug> <ca slug> <cn> <san list>
make_leaf() {
  local slug="$1" ca="$2" cn="$3" sans="$4"
  if [[ -f "${slug}.crt" && -f "${slug}.key" ]]; then
    log "reusing ${slug}.crt"
    return 0
  fi
  openssl req -newkey rsa:2048 -sha256 -nodes \
    -keyout "${slug}.key" -out "${slug}.csr" -subj "/CN=${cn}" >/dev/null 2>&1
  openssl x509 -req -in "${slug}.csr" -CA "${ca}.crt" -CAkey "${ca}.key" \
    -CAcreateserial -out "${slug}.crt" -days 825 -sha256 \
    -extfile <(printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth\n' "$sans") >/dev/null 2>&1
  rm -f "${slug}.csr"
  ok "leaf ${slug} (${sans})"
}

step "Generating certificate authorities"
make_ca upstream-ca "ACME External Root CA"
make_ca corp-ca     "Corp Inspection CA"

step "Generating server certificates"
# One certificate, both destination names: the resolvable one used by the
# direct and tunnelled tests, and the unresolvable one used by the air-gap test.
make_leaf api upstream-ca "$API_HOST" "DNS:${API_HOST},DNS:${AIRGAP_HOST}"
# The TLS front door on the proxy. Signed by corp-ca so the gateway can verify
# the proxy itself, separately from verifying the destination.
make_leaf proxy corp-ca "proxy.${EGRESS_NS}.svc.cluster.local" \
  "DNS:proxy.${EGRESS_NS}.svc.cluster.local,DNS:squid-tls.${EGRESS_NS}.svc.cluster.local"

# mitmproxy wants its CA as one PEM holding the key and the certificate.
cat corp-ca.key corp-ca.crt > mitmproxy-ca.pem

step "Creating namespaces"
for ns in "$UPSTREAM_NS" "$EGRESS_NS"; do
  kc get ns "$ns" >/dev/null 2>&1 || kc create ns "$ns" >/dev/null
done
ok "namespaces $UPSTREAM_NS, $EGRESS_NS"

step "Loading certificates into the cluster"

# The destination API's serving certificate.
kc -n "$UPSTREAM_NS" create secret tls api-tls \
  --cert=api.crt --key=api.key --dry-run=client -o yaml | kc apply -f - >/dev/null
ok "secret $UPSTREAM_NS/api-tls (destination serving cert)"

# mitmproxy's signing CA, and the CA it should trust when it re-originates TLS
# to the real destination.
kc -n "$EGRESS_NS" create secret generic mitm-ca \
  --from-file=mitmproxy-ca.pem=mitmproxy-ca.pem \
  --from-file=upstream-ca.crt=upstream-ca.crt \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
ok "secret $EGRESS_NS/mitm-ca (inspection CA + upstream trust)"

# The proxy's own TLS front door.
kc -n "$EGRESS_NS" create secret tls proxy-tls \
  --cert=proxy.crt --key=proxy.key --dry-run=client -o yaml | kc apply -f - >/dev/null
ok "secret $EGRESS_NS/proxy-tls (TLS front door on the proxy)"

# Squid's basic-auth password file, and the same credential in the form the
# gateway sends it: a base64 Basic token.
if command -v htpasswd >/dev/null 2>&1; then
  htpasswd -bc squid-passwd "$PROXY_USER" "$PROXY_PASS" >/dev/null 2>&1
else
  # openssl's apr1 hash is what Squid's basic_ncsa_auth expects.
  printf '%s:%s\n' "$PROXY_USER" "$(openssl passwd -apr1 "$PROXY_PASS")" > squid-passwd
fi
kc -n "$EGRESS_NS" create secret generic squid-passwd \
  --from-file=passwd=squid-passwd --dry-run=client -o yaml | kc apply -f - >/dev/null
ok "secret $EGRESS_NS/squid-passwd (proxy credentials, Squid side)"

# ── what agentgateway itself reads ───────────────────────────────────────────
# caCertificateRefs takes a ConfigMap (the default) or a Secret, and in both
# cases the CA has to be under the key ca.crt. Any other key is rejected as a
# missing CA certificate, so both objects use that name.
kc -n "$AGW_NS" create configmap upstream-ca \
  --from-file=ca.crt=upstream-ca.crt --dry-run=client -o yaml | kc apply -f - >/dev/null
ok "configmap $AGW_NS/upstream-ca (key: ca.crt)"

kc -n "$AGW_NS" create configmap corp-ca \
  --from-file=ca.crt=corp-ca.crt --dry-run=client -o yaml | kc apply -f - >/dev/null
ok "configmap $AGW_NS/corp-ca (key: ca.crt)"

# The same corporate CA as a Secret, to prove kind: Secret resolves too.
kc -n "$AGW_NS" create secret generic corp-ca-secret \
  --from-file=ca.crt=corp-ca.crt --dry-run=client -o yaml | kc apply -f - >/dev/null
ok "secret $AGW_NS/corp-ca-secret (key: ca.crt)"

# The Basic credential the gateway puts on the CONNECT request. Squid checks it
# against squid-passwd above.
printf '%s' "$(printf '%s:%s' "$PROXY_USER" "$PROXY_PASS" | base64)" > proxy-basic.txt
kc -n "$AGW_NS" create secret generic proxy-credentials \
  --from-file=authorization=proxy-basic.txt --dry-run=client -o yaml | kc apply -f - >/dev/null
ok "secret $AGW_NS/proxy-credentials (Basic token, gateway side)"

step "PKI ready"
echo "  Next: ./scripts/04-upstream.sh" >&2
