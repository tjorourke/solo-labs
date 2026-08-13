#!/usr/bin/env bash
# TLS on the public gateway. Terminated at agentgateway, plaintext downgraded to a
# redirect. A zero-trust edge does not serve the model over HTTP.
#
#   ./scripts/tls.sh up       issue the edge cert, add the HTTPS listener, redirect HTTP
#   ./scripts/tls.sh url      the https URL to call
#   ./scripts/tls.sh cacert   write the CA to a file so curl/Cursor can trust it
#   ./scripts/tls.sh test     a real HTTPS chat completion through the gateway
#
# The certificate is issued by a dedicated edge CA (cert-manager), kept separate from
# the mesh PKI in Vault: the mesh CA secures workload-to-workload identity inside the
# cluster, this secures the public listener. A real deployment swaps this for an ACM or
# public-CA certificate on a real domain, which is a DNS record and a certificateRef
# away; nothing else changes.
set -euo pipefail

export AWS_PROFILE="${SOVEREIGN_AWS_PROFILE:?set SOVEREIGN_AWS_PROFILE to the sandbox SSO profile}"
REGION=eu-west-2
CLUSTER=uk-sovereign-ai
GW_NS=agentgateway-system

ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
[ -n "$ACCOUNT" ] && [ "$ACCOUNT" != "None" ] || { echo "error: no AWS identity; check SOVEREIGN_AWS_PROFILE" >&2; exit 1; }
CTX="arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${CLUSTER}"
kc() { command kubectl --context "$CTX" "$@"; }
LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CADIR="${GW_CACERT_DIR:-$HOME/.solo-sovereign}"

host() { kc -n "$GW_NS" get svc sovereign-gateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null; }

case "${1:-up}" in
  up)
    HOST="$(host)"
    [ -n "$HOST" ] || { echo "error: gateway has no NLB hostname yet" >&2; exit 1; }
    echo "==> edge cert for https://${HOST}"

    # Dedicated self-signed edge CA -> leaf for the NLB hostname. Separate from the mesh
    # PKI on purpose: this is the public edge, not workload identity.
    kc apply -f - >/dev/null <<TLS
apiVersion: cert-manager.io/v1
kind: Issuer
metadata: { name: gateway-edge-selfsign, namespace: ${GW_NS} }
spec: { selfSigned: {} }
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: { name: gateway-edge-ca, namespace: ${GW_NS} }
spec:
  isCA: true
  commonName: UK Sovereign AI Edge CA
  secretName: gateway-edge-ca
  duration: 8760h
  privateKey: { algorithm: RSA, size: 4096 }
  issuerRef: { name: gateway-edge-selfsign, kind: Issuer, group: cert-manager.io }
---
apiVersion: cert-manager.io/v1
kind: Issuer
metadata: { name: gateway-edge-ca, namespace: ${GW_NS} }
spec:
  ca: { secretName: gateway-edge-ca }
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: { name: gateway-tls, namespace: ${GW_NS} }
spec:
  secretName: gateway-tls
  duration: 2160h              # 90 days, auto-renewed by cert-manager
  # No commonName: the NLB hostname is 69 bytes and a cert CN is capped at 64. Modern
  # TLS validates the SAN, not the CN, so the hostname lives in dnsNames only.
  dnsNames: [ ${HOST} ]
  privateKey: { algorithm: RSA, size: 2048 }
  issuerRef: { name: gateway-edge-ca, kind: Issuer, group: cert-manager.io }
---
# A second edge cert for the *.sovereign.local console hostnames (kagent, registry, age,
# keycloak). Signed by the SAME edge CA, so a laptop that trusts gateway-ca.crt validates
# every console and Keycloak's external hostname. It rides its own SNI listener on the
# Gateway (yaml/30-gateway.yaml, listener https-sovereign-local), leaving gateway-tls above
# (the model door) untouched.
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: { name: sovereign-local-tls, namespace: ${GW_NS} }
spec:
  secretName: sovereign-local-tls
  duration: 2160h
  dnsNames: [ "*.sovereign.local" ]
  privateKey: { algorithm: RSA, size: 2048 }
  issuerRef: { name: gateway-edge-ca, kind: Issuer, group: cert-manager.io }
TLS
    kc -n "$GW_NS" wait --for=condition=Ready certificate/gateway-tls --timeout=120s >/dev/null
    kc -n "$GW_NS" wait --for=condition=Ready certificate/sovereign-local-tls --timeout=120s >/dev/null
    echo "    certs issued into secrets gateway-tls and sovereign-local-tls"

    echo "==> HTTPS listener on the Gateway, HTTP downgraded to a redirect"
    kc apply -f "$LAB_ROOT/yaml/30-gateway.yaml" >/dev/null
    kc apply -f "$LAB_ROOT/yaml/31-vllm-backend.yaml" >/dev/null
    echo "    waiting for the Gateway to reprogram with :443"
    for _ in $(seq 1 40); do
      kc -n "$GW_NS" get gateway sovereign-gateway -o jsonpath='{.spec.listeners[*].port}' 2>/dev/null | grep -q 443 && break
      sleep 5
    done
    kc -n "$GW_NS" get gateway sovereign-gateway \
      -o jsonpath='{range .spec.listeners[*]}{.name}{" "}{.protocol}{":"}{.port}{"\n"}{end}'
    echo
    "$0" cacert
    echo "done. Call it: $0 test    (or: $0 url)"
    ;;

  url)
    HOST="$(host)"; [ -n "$HOST" ] || { echo "no NLB hostname" >&2; exit 1; }
    echo "https://${HOST}"
    ;;

  cacert)
    mkdir -p "$CADIR"
    kc -n "$GW_NS" get secret gateway-edge-ca -o jsonpath='{.data.tls\.crt}' | base64 -d > "$CADIR/gateway-ca.crt"
    echo "    CA written to $CADIR/gateway-ca.crt"
    echo "    curl:   --cacert $CADIR/gateway-ca.crt"
    echo "    Cursor: import that file as a trusted root, then base URL https://$(host)/v1"
    ;;

  test)
    HOST="$(host)"; CA="$CADIR/gateway-ca.crt"
    [ -f "$CA" ] || "$0" cacert >/dev/null
    echo "==> HTTPS POST https://${HOST}/v1/chat/completions"
    code=$(curl -s --cacert "$CA" -o /tmp/tls-test.json -w '%{http_code}' --max-time 120 \
      -X POST "https://${HOST}/v1/chat/completions" -H 'content-type: application/json' \
      -d '{"model":"mistral-small-3.2-24b","max_tokens":40,"messages":[{"role":"user","content":"Confirm in one line that this request arrived over TLS."}]}')
    echo "    HTTP $code over TLS"
    [ "$code" = "200" ] && python3 -c 'import json;print("   ",json.load(open("/tmp/tls-test.json"))["choices"][0]["message"]["content"].strip())'
    echo "==> and plain HTTP is refused / redirected:"
    curl -s -o /dev/null -w '    http://%{http_code} (Location: %{redirect_url})\n' --max-time 15 \
      "http://${HOST}/v1/chat/completions" || true
    ;;

  *) echo "usage: $0 {up|url|cacert|test}"; exit 1 ;;
esac
