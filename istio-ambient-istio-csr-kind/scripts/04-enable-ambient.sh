#!/usr/bin/env bash
# 04-enable-ambient.sh — the ambient control-plane arrives, with NO workloads
# enrolled and NO Vault changes. Four moves, in order:
#
#   1. istio-csr: add app.server.caTrustedNodeAccounts=istio-system/ztunnel —
#      the ambient trust model. A sidecar requests a cert for its own pod
#      identity; ztunnel authenticates as itself and requests certs for the
#      workload identities it fronts on its node. This flag is what authorises
#      that impersonation (istio-csr >= v0.12.0).
#   2. istiod: helm upgrade to profile=ambient (same release, same values,
#      sidecars keep running).
#   3. istio-cni (node agent, ambient profile).
#   4. ztunnel, with caAddress pointed at istio-csr like every other proxy.
#
# After this script the mesh is bilingual (sidecar + ambient) but nothing has
# moved: both app namespaces still run sidecars with RSA certs, and their
# existing certificates are untouched (same serials — the e2e proves it).
# ztunnel is up but has issued no CSRs yet: it only requests certs for
# ENROLLED workloads, and nothing is enrolled.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require helm; require kubectl; require jq

HVER="$ISTIO_HELM_VERSION"

step "istio-csr: authorise ztunnel to request certs for the workloads it fronts"
helm --kube-context "$CTX" upgrade cert-manager-istio-csr cert-manager-istio-csr \
  --repo https://charts.jetstack.io \
  -n "$CM_NS" --version "$ISTIO_CSR_VERSION" --wait \
  --reuse-values \
  --set "app.server.caTrustedNodeAccounts=${ISTIO_SYSTEM_NS}/ztunnel" >/dev/null
ok "istio-csr reconfigured (caTrustedNodeAccounts=${ISTIO_SYSTEM_NS}/ztunnel) — sidecar apps unaffected"

step "istiod: helm upgrade to profile=ambient (sidecars keep serving)"
# shellcheck disable=SC2046
helm --kube-context "$CTX" upgrade istiod $(helm_chart istiod) \
  -n "$ISTIO_SYSTEM_NS" --version "$HVER" --wait \
  --reuse-values \
  --set profile=ambient \
  --set istio_cni.enabled=true >/dev/null
kc -n "$ISTIO_SYSTEM_NS" rollout status deploy/istiod --timeout=180s >/dev/null
ok "istiod now speaks ambient too"

step "Helm: istio-cni (ambient node agent)"
# shellcheck disable=SC2046
helm --kube-context "$CTX" upgrade -i istio-cni $(helm_chart cni) \
  -n "$ISTIO_SYSTEM_NS" --version "$HVER" --wait -f - >/dev/null <<EOF
profile: ambient
global:
  hub: ${ISTIO_REGISTRY}
  tag: ${ISTIO_VERSION}
excludeNamespaces:
  - ${ISTIO_SYSTEM_NS}
  - kube-system
  - ${CM_NS}
  - ${VAULT_NS}
EOF
kc -n "$ISTIO_SYSTEM_NS" rollout status daemonset/istio-cni-node --timeout=180s >/dev/null
ok "istio-cni running on every node"

step "Helm: ztunnel — caAddress -> istio-csr, same as every other proxy"
# shellcheck disable=SC2046
helm --kube-context "$CTX" upgrade -i ztunnel $(helm_chart ztunnel) \
  -n "$ISTIO_SYSTEM_NS" --version "$HVER" --wait -f - >/dev/null <<EOF
profile: ambient
hub: ${ISTIO_REGISTRY}
tag: ${ISTIO_VERSION}
istioNamespace: ${ISTIO_SYSTEM_NS}
caAddress: cert-manager-istio-csr.${CM_NS}.svc:443
env:
  LOG_FORMAT: json
EOF
kc -n "$ISTIO_SYSTEM_NS" rollout status daemonset/ztunnel --timeout=180s >/dev/null
ok "ztunnel running on every node — zero CSRs sent (nothing is enrolled yet)"

echo
ok "Ambient control plane in place. Both app namespaces still on sidecars, certs untouched."
log "Next: ./scripts/05-interop-roll.sh — sidecars injected before the ambient"
log "profile lack ISTIO_META_ENABLE_HBONE, and ztunnel can only reach those in"
log "plaintext (STRICT rejects it). One roll fixes it."
