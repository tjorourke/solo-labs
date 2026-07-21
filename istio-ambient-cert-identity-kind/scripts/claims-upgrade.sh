#!/usr/bin/env bash
# claims-upgrade.sh — in-place upgrade of the mesh to the Solo Istio 1.30 line
# with workload claims on. This is the §13 step: the 1.29 mesh keeps running,
# the control plane and ztunnel roll to 1.30.x, and ztunnel starts requesting a
# certificate PER POD (cache keyed by pod UID) instead of one per ServiceAccount.
#
# The one versioning trap: on the 1.30 line the -solo suffix stays on the IMAGE
# tag too (ztunnel:1.30.3-solo). The plain 1.30.3 tag in the same registry is
# the upstream build — it installs cleanly and then silently has no
# enableWorkloadClaims, so the CEL policy fail-closes and everything is denied.
#
# Also resets the L7 story (waypoint + JWT policies) first — workload claims is
# a pure L4 capability and the demo reads cleanest with only L4 policy applied.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require kind; require kubectl; require helm; require docker; require gcloud
check_docker; check_gcloud; require_secrets

# chart version AND image tag — both keep -solo on the 1.30 line
export CLAIMS_ISTIO_VERSION="${CLAIMS_ISTIO_VERSION:-1.30.3-solo}"

step "Back to a pure L4 story (remove the L7 waypoint + JWT policies)"
kc -n "$NS_APP" delete authorizationpolicy petstore-jwt-authz --ignore-not-found >/dev/null
kc -n "$NS_APP" delete requestauthentication petshop-jwt --ignore-not-found >/dev/null
kc label namespace "$NS_APP" istio.io/use-waypoint- >/dev/null 2>&1 || true
kc -n "$NS_APP" delete gateway petstore-waypoint --ignore-not-found >/dev/null
ok "L7 objects removed; only L4 identity remains"

step "Pre-pulling Solo Istio $CLAIMS_ISTIO_VERSION images and loading into kind"
__tar_tmp="$(mktemp -d)"; trap 'rm -rf "$__tar_tmp"' EXIT
for name in pilot proxyv2 install-cni ztunnel; do
  img="$ISTIO_REGISTRY/$name:$CLAIMS_ISTIO_VERSION"
  docker image inspect "$img" >/dev/null 2>&1 || { log "pulling $img …"; docker pull --quiet "$img" >/dev/null; }
  tar="$__tar_tmp/$(echo "$img" | tr '/:' '__').tar"
  docker save --platform "$KIND_PLATFORM" "$img" -o "$tar"
  log "loading $name:$CLAIMS_ISTIO_VERSION into kind …"
  kind load image-archive "$tar" --name "$CLUSTER_NAME" >/dev/null
  rm -f "$tar"
done
ok "1.30-line images loaded"

HREPO="$ISTIO_HELM_REPO"; HVER="$CLAIMS_ISTIO_VERSION"; TAG="$CLAIMS_ISTIO_VERSION"

step "Helm: upgrade istio-base to $HVER"
helm --kube-context "$CTX" upgrade -i istio-base "$HREPO/base" \
  -n "$ISTIO_SYSTEM_NS" --version "$HVER" --set defaultRevision=default --wait >/dev/null
ok "istio-base upgraded"

step "Helm: upgrade istiod to $HVER (same values — no claims flag needed on istiod)"
helm --kube-context "$CTX" upgrade -i istiod "$HREPO/istiod" \
  -n "$ISTIO_SYSTEM_NS" --version "$HVER" --wait -f - >/dev/null <<EOF
profile: ambient
global:
  hub: ${ISTIO_REGISTRY}
  tag: ${TAG}
istio_cni:
  enabled: true
license:
  value: ${SOLO_ISTIO_LICENSE_KEY}
env:
  PILOT_SKIP_VALIDATE_TRUST_DOMAIN: "true"
meshConfig:
  accessLogFile: /dev/stdout
  trustDomain: ${TRUST_DOMAIN}
EOF
kc -n "$ISTIO_SYSTEM_NS" rollout status deploy/istiod --timeout=180s >/dev/null
ok "istiod on $TAG"

step "Helm: upgrade istio-cni to $HVER"
helm --kube-context "$CTX" upgrade -i istio-cni "$HREPO/cni" \
  -n "$ISTIO_SYSTEM_NS" --version "$HVER" --wait -f - >/dev/null <<EOF
profile: ambient
global:
  hub: ${ISTIO_REGISTRY}
  tag: ${TAG}
ambient:
  dnsCapture: true
excludeNamespaces:
  - istio-system
  - kube-system
EOF
ok "istio-cni on $TAG"

step "Helm: upgrade ztunnel to $HVER with ENABLE_WORKLOAD_CLAIMS=true"
helm --kube-context "$CTX" upgrade -i ztunnel "$HREPO/ztunnel" \
  -n "$ISTIO_SYSTEM_NS" --version "$HVER" --wait -f - >/dev/null <<EOF
profile: ambient
hub: ${ISTIO_REGISTRY}
tag: ${TAG}
namespace: ${ISTIO_SYSTEM_NS}
istioNamespace: ${ISTIO_SYSTEM_NS}
env:
  LOG_FORMAT: json
  L7_ENABLED: "true"
  # per-POD certs (cache keyed by pod UID) + claims extraction/enforcement
  ENABLE_WORKLOAD_CLAIMS: "true"
EOF
kc -n "$ISTIO_SYSTEM_NS" rollout status daemonset/ztunnel --timeout=180s >/dev/null
kc -n "$ISTIO_SYSTEM_NS" rollout status daemonset/istio-cni-node --timeout=180s >/dev/null
ok "ztunnel on $TAG, workload claims ON"

echo
ok "Mesh upgraded in place to $CLAIMS_ISTIO_VERSION. Every workload now gets a per-pod cert."
log "Next: make claims — annotate checkout blue/gold green/silver + apply the CEL policy."
