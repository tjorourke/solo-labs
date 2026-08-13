#!/usr/bin/env bash
# Move the mesh CA from istiod to Vault, so the root of trust is something you hold.
#
#   ./scripts/istio-csr.sh up       cert-manager + Vault + PKI + istio-csr, then rewire the mesh
#   ./scripts/istio-csr.sh certs    show a real workload certificate and who signed it
#   ./scripts/istio-csr.sh status   what is installed, the Vault role, and the CSR ledger
#   ./scripts/istio-csr.sh down     remove it (leaves the mesh without a CA, see the note)
#
# WHY THIS EXISTS IN A SOVEREIGNTY LAB. Without it the honest answer to "where is your
# root of trust?" is "a self-signed key inside istiod's pod". With it, every workload
# certificate in the mesh is signed by a CA you run, in eu-west-2, and every issuance
# leaves a CertificateRequest behind as an audit record. Geography is only half of
# sovereignty; the other half is who holds the keys.
#
# RUN THIS BEFORE ADDING MORE WORKLOADS. Changing CA means re-issuing every certificate
# in the mesh, so it costs a ztunnel roll and a restart of everything enrolled. That is
# cheap with three namespaces and expensive with ten.
set -euo pipefail

export AWS_PROFILE="${SOVEREIGN_AWS_PROFILE:?set SOVEREIGN_AWS_PROFILE to the sandbox SSO profile}"
REGION=eu-west-2
CLUSTER=uk-sovereign-ai

ISTIO_NS=istio-system
CM_NS=cert-manager
VAULT_NS=vault
TRUST_DOMAIN="${TRUST_DOMAIN:-cluster.local}"

CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.21.1}"
ISTIO_CSR_VERSION="${ISTIO_CSR_VERSION:-v0.16.0}"
VAULT_CHART_VERSION="${VAULT_CHART_VERSION:-0.34.0}"
SOLO_ISTIO_VERSION="${SOLO_ISTIO_VERSION:-1.30.3-solo}"
ISTIO_REGISTRY="${ISTIO_REGISTRY:-us-docker.pkg.dev/soloio-img/istio}"
HREPO="${ISTIO_HELM_REPO:-oci://us-docker.pkg.dev/soloio-img/istio-helm}"

ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
[ -n "$ACCOUNT" ] && [ "$ACCOUNT" != "None" ] || { echo "error: no AWS identity; check SOVEREIGN_AWS_PROFILE" >&2; exit 1; }
CTX="arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${CLUSTER}"
kc() { command kubectl --context "$CTX" "$@"; }
helm_() { command helm --kube-context "$CTX" "$@"; }

license() {
  if [ -z "${SOLO_ISTIO_LICENSE_KEY:-}" ]; then
    # Optional convenience: point SOVEREIGN_ENV_FILE at your own env file that exports
    # the licence keys. Otherwise export them directly. No path is hardcoded, and no
    # secret ever lives in this repo.
    # shellcheck disable=SC1090
    [ -n "${SOVEREIGN_ENV_FILE:-}" ] && [ -f "$SOVEREIGN_ENV_FILE" ] && . "$SOVEREIGN_ENV_FILE" >/dev/null 2>&1 || true
  fi
  [ -n "${SOLO_ISTIO_LICENSE_KEY:-}" ] || {
    echo "error: SOLO_ISTIO_LICENSE_KEY is not set. source your secrets env first." >&2; exit 1; }
}

case "${1:-status}" in
  up)
    license

    echo "==> cert-manager $CERT_MANAGER_VERSION"
    helm_ upgrade -i cert-manager cert-manager --repo https://charts.jetstack.io \
      -n "$CM_NS" --create-namespace --version "$CERT_MANAGER_VERSION" \
      --set crds.enabled=true --wait >/dev/null
    echo "    ok"

    # Vault, its PKI and the cert-manager Issuer are owned by scripts/vault.sh, which
    # installs Vault raft-backed with KMS auto-unseal and a TLS listener. This script
    # used to install a dev-mode Vault here and create an http:// Issuer, and that pair
    # is exactly how the CA migration broke: once Vault serves TLS, cert-manager gets
    # "connection reset by peer" on the http Issuer, which reads like a network fault
    # rather than a URL scheme mistake. Worse, re-running this would have reinstalled
    # dev Vault OVER the production one and silently replaced the root of trust.
    echo "==> checking Vault and the istio-ca Issuer exist (scripts/vault.sh owns both)"
    kc -n "$VAULT_NS" get pod vault-0 >/dev/null 2>&1 || {
      echo "error: vault-0 not found. Run ./scripts/vault.sh up first." >&2; exit 1; }
    ready="$(kc -n "$VAULT_NS" get pod vault-0 -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)"
    [ "$ready" = "true" ] || {
      echo "error: vault-0 is not ready (sealed?). Check ./scripts/vault.sh status." >&2; exit 1; }
    iss="$(kc -n "$ISTIO_NS" get issuer istio-ca -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
    [ "$iss" = "True" ] || {
      echo "error: Issuer istio-ca is not Ready. Run ./scripts/vault.sh pki." >&2; exit 1; }
    echo "    Vault ready, Issuer istio-ca Ready, server=$(kc -n "$ISTIO_NS" get issuer istio-ca -o jsonpath='{.spec.vault.server}')"

    echo "==> istio-csr $ISTIO_CSR_VERSION"
    # caTrustedNodeAccounts is REQUIRED for ambient. ztunnel requests certificates on
    # behalf of every pod on its node, which istio-csr refuses by default because it
    # looks exactly like a workload asking for someone else's identity. Without it,
    # every enrolled pod fails to get a certificate and the mesh silently stops
    # carrying traffic.
    #
    # preserveCertificateRequests keeps every CertificateRequest object, which is the
    # audit trail: what was signed, for which identity, and when.
    helm_ upgrade -i cert-manager-istio-csr cert-manager-istio-csr \
      --repo https://charts.jetstack.io -n "$CM_NS" --version "$ISTIO_CSR_VERSION" \
      --wait -f - >/dev/null <<CSR
replicaCount: 1
app:
  logLevel: 2
  certmanager:
    namespace: ${ISTIO_NS}
    preserveCertificateRequests: true
    issuer:
      name: istio-ca
      kind: Issuer
      group: cert-manager.io
  tls:
    trustDomain: ${TRUST_DOMAIN}
    rootCAFile: /var/run/secrets/istio-csr/ca.pem
    certificateDNSNames:
      - cert-manager-istio-csr.${CM_NS}.svc
  server:
    clusterID: Kubernetes
    caTrustedNodeAccounts: ${ISTIO_NS}/ztunnel
  istio:
    revisions: ["default"]
volumeMounts:
  - name: root-ca
    mountPath: /var/run/secrets/istio-csr
volumes:
  - name: root-ca
    secret:
      secretName: istio-root-ca
CSR
    echo "    ok, istiod-tls issued through Vault"

    echo "==> istiod: built-in CA OFF, every proxy asks istio-csr"
    helm_ upgrade -i istiod "$HREPO/istiod" -n "$ISTIO_NS" \
      --version "$SOLO_ISTIO_VERSION" --wait -f - >/dev/null <<EOF
profile: ambient
global:
  hub: ${ISTIO_REGISTRY}
  tag: ${SOLO_ISTIO_VERSION}
  caAddress: cert-manager-istio-csr.${CM_NS}.svc:443
istio_cni:
  enabled: true
license:
  value: ${SOLO_ISTIO_LICENSE_KEY}
pilot:
  env:
    # istiod signs nothing from here on. Vault is the only CA in this mesh.
    ENABLE_CA_SERVER: "false"
    # Do NOT let istiod manage the webhook caBundles. With its built-in CA off, istiod keeps
    # stamping its stale self-signed root (O=cluster.local) onto the validation and injection
    # webhook configs, which no longer matches its istio-csr (Vault) signed serving cert, so
    # every Istio CR apply fails the validation webhook with "certificate signed by unknown
    # authority". We point the caBundle at the Vault root ourselves, just after this install.
    VALIDATION_WEBHOOK_CONFIG_NAME: ""
    INJECTION_WEBHOOK_CONFIG_NAME: ""
meshConfig:
  accessLogFile: /dev/stdout
  trustDomain: ${TRUST_DOMAIN}
EOF
    kc -n "$ISTIO_NS" rollout status deploy/istiod --timeout=300s
    echo "    ok"

    # Point the Istio webhooks at the Vault root, so the API server trusts istiod's
    # istio-csr-signed serving cert. istiod no longer manages these (envs above), so it sticks.
    # Without this, applying any Istio CR (yaml/33, 48, 49) fails the validation webhook.
    echo "==> webhook caBundle -> Vault root (istio-ca-root-cert)"
    for _ in $(seq 1 30); do
      kc -n "$ISTIO_NS" get cm istio-ca-root-cert >/dev/null 2>&1 && break; sleep 2
    done
    cab="$(kc -n "$ISTIO_NS" get cm istio-ca-root-cert -o jsonpath='{.data.root-cert\.pem}' | base64 | tr -d '\n')"
    for kind in validatingwebhookconfiguration mutatingwebhookconfiguration; do
      for wc in $(kc get "$kind" -o name 2>/dev/null | grep -i istio | sed 's#.*/##'); do
        n="$(kc get "$kind" "$wc" -o jsonpath='{.webhooks}' | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)"
        for i in $(seq 0 $((n-1))); do
          kc patch "$kind" "$wc" --type json \
            -p "[{\"op\":\"replace\",\"path\":\"/webhooks/$i/clientConfig/caBundle\",\"value\":\"$cab\"}]" >/dev/null 2>&1 || true
        done
      done
    done
    echo "    webhooks trust the Vault root"

    # cert-manager and vault MUST stay out of the mesh. They are what issues the
    # certificates ztunnel needs, so capturing them creates a deadlock: no certs
    # without cert-manager, and no cert-manager traffic without certs.
    echo "==> istio-cni: keep the CA path out of the mesh"
    helm_ upgrade -i istio-cni "$HREPO/cni" -n "$ISTIO_NS" \
      --version "$SOLO_ISTIO_VERSION" --wait -f - >/dev/null <<EOF
profile: ambient
global:
  hub: ${ISTIO_REGISTRY}
  tag: ${SOLO_ISTIO_VERSION}
ambient:
  dnsCapture: true
excludeNamespaces:
  - ${ISTIO_NS}
  - kube-system
  - ${CM_NS}
  - ${VAULT_NS}
EOF
    echo "    ok"

    echo "==> ztunnel: caAddress -> istio-csr"
    helm_ upgrade -i ztunnel "$HREPO/ztunnel" -n "$ISTIO_NS" \
      --version "$SOLO_ISTIO_VERSION" --wait -f - >/dev/null <<EOF
profile: ambient
hub: ${ISTIO_REGISTRY}
tag: ${SOLO_ISTIO_VERSION}
namespace: ${ISTIO_NS}
istioNamespace: ${ISTIO_NS}
caAddress: cert-manager-istio-csr.${CM_NS}.svc:443
env:
  LOG_FORMAT: json
  L7_ENABLED: "true"
EOF
    kc -n "$ISTIO_NS" rollout status daemonset/ztunnel --timeout=300s
    echo "    ok"
    echo
    # No workload restart is needed, and that is worth stating because the sidecar
    # instinct says otherwise. In ambient the workload certificate lives in ztunnel,
    # not in the pod, so rolling ztunnel is what re-fetches every identity from the new
    # CA. Measured on this cluster: within seconds of the ztunnel roll, Vault had signed
    # certs for models/default, keycloak/default and all six agentgateway identities,
    # with no pod having restarted. Restarting vLLM to "pick up" a certificate it never
    # held would cost a model reload for nothing.
    echo "The mesh CA is now Vault, and no workload restart is required:"
    echo "in ambient the certificate lives in ztunnel, so the ztunnel roll already"
    echo "re-fetched every identity from Vault. Confirm with:"
    echo "  ./scripts/istio-csr.sh certs"
    ;;

  certs)
    echo "=== the mesh trust anchor (published by vault.sh)"
    kc -n "$CM_NS" get secret istio-root-ca -o jsonpath='{.data.ca\.pem}' 2>/dev/null \
      | base64 -d | openssl x509 -noout -subject -dates 2>/dev/null
    echo
    echo "=== CertificateRequests signed through Vault (the audit trail)"
    kc -n "$ISTIO_NS" get certificaterequests \
      -o custom-columns='NAME:.metadata.name,APPROVED:.status.conditions[?(@.type=="Approved")].status,READY:.status.conditions[?(@.type=="Ready")].status,AGE:.metadata.creationTimestamp' \
      2>/dev/null | head -12
    echo
    echo "=== a real workload certificate, and who signed it"
    # Asking ztunnel rather than reading a Secret: ambient certs never touch the API
    # server, they live in ztunnel's memory, which is the point of the design.
    zt=$(kc -n "$ISTIO_NS" get pods -l app=ztunnel -o name | head -1)
    [ -n "$zt" ] && kc -n "$ISTIO_NS" exec "$zt" -c istio-proxy -- \
      curl -s localhost:15000/config_dump 2>/dev/null | head -40 || \
      echo "  (use: istioctl proxy-config secret <pod> for a decoded view)"
    ;;

  status)
    echo "=== cert-manager / Vault / istio-csr"
    kc -n "$CM_NS" get pods --no-headers 2>/dev/null | head
    kc -n "$VAULT_NS" get pods --no-headers 2>/dev/null | head -3
    echo
    echo "=== Vault (see ./scripts/vault.sh status for seal state and the signing role)"
    kc -n "$VAULT_NS" get pods --no-headers 2>/dev/null | head -2
    echo
    echo "=== is istiod still a CA? (want ENABLE_CA_SERVER=false)"
    kc -n "$ISTIO_NS" get deploy istiod \
      -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' 2>/dev/null \
      | grep -E 'ENABLE_CA_SERVER' || echo "  not set (istiod would still sign)"
    echo
    echo "=== where proxies fetch certificates"
    kc -n "$ISTIO_NS" get deploy istiod \
      -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="CA_ADDR")].value}{"\n"}' 2>/dev/null
    kc -n "$ISTIO_NS" get ds ztunnel \
      -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="CA_ADDRESS")].value}{"\n"}' 2>/dev/null
    ;;

  down)
    # Deliberately loud. Removing istio-csr without putting istiod's CA back leaves a
    # mesh that cannot issue certificates: nothing breaks until the first renewal, and
    # then everything does, an hour later, for no visible reason.
    echo "WARNING: this removes the mesh's only CA."
    echo "Re-enable istiod's built-in CA first, or the mesh dies at the next renewal:"
    echo "  helm upgrade istiod ... --set pilot.env.ENABLE_CA_SERVER=true --set global.caAddress="
    read -r -p "type 'yes' to continue: " a
    [ "$a" = "yes" ] || exit 1
    helm_ uninstall cert-manager-istio-csr -n "$CM_NS" >/dev/null 2>&1 || true
    # Vault is NOT removed here: it holds the CA and is owned by scripts/vault.sh.
    helm_ uninstall cert-manager -n "$CM_NS" >/dev/null 2>&1 || true
    echo "removed"
    ;;

  *) echo "usage: $0 {up|certs|status|down}"; exit 1 ;;
esac
