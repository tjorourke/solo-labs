#!/usr/bin/env bash
# ambient-enable.sh — the mesh-level switch: the ambient dataplane arrives,
# with NO workloads enrolled. Three helm commands, in order:
#
#   1. istiod: helm upgrade to profile=ambient (same release, same values —
#      sidecars keep running and keep being injected).
#   2. istio-cni (the ambient node agent that redirects enrolled pods).
#   3. ztunnel (the per-node L4 proxy).
#
# After this the mesh is bilingual (sidecar + ambient) but nothing has moved:
# every app namespace still runs sidecars, and traffic is untouched. Enrolment
# is per-namespace, later, with one label.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require helm; require kubectl

HVER="$ISTIO_HELM_VERSION"

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
EOF
kc -n "$ISTIO_SYSTEM_NS" rollout status daemonset/istio-cni-node --timeout=180s >/dev/null
ok "istio-cni running on every node"

step "Helm: ztunnel (per-node L4 proxy)"
# shellcheck disable=SC2046
helm --kube-context "$CTX" upgrade -i ztunnel $(helm_chart ztunnel) \
  -n "$ISTIO_SYSTEM_NS" --version "$HVER" --wait -f - >/dev/null <<EOF
profile: ambient
hub: ${ISTIO_REGISTRY}
tag: ${ISTIO_VERSION}
istioNamespace: ${ISTIO_SYSTEM_NS}
env:
  LOG_FORMAT: json
EOF
kc -n "$ISTIO_SYSTEM_NS" rollout status daemonset/ztunnel --timeout=180s >/dev/null
ok "ztunnel running on every node — nothing enrolled yet"

echo
ok "Ambient dataplane in place. Every app namespace still on sidecars, traffic untouched."
log "Next: roll each sidecar namespace once (sidecars injected before the ambient"
log "profile lack ISTIO_META_ENABLE_HBONE, and ztunnel can only reach those in"
log "plaintext — which STRICT mTLS rejects). Then enrol namespaces one label at a time."
