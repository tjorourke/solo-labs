#!/usr/bin/env bash
# setup-cluster.sh — stands up kind + Solo Istio in AMBIENT mode using the
# Helm charts directly (NO Gloo Operator). Everything the operator would hide —
# the licence, the trust domain, JSON access logs — is a plain Helm value here,
# set up front, so there are no post-hoc kubectl patches. Everything after this
# (the app and the policies) is plain YAML you apply yourself from the README.
#
# What it does:
#   1. kind cluster (1 control-plane + 1 worker)
#   2. Gateway API CRDs
#   3. Pre-pull the Solo Istio images on the host and kind-load them
#   4. Helm: base, then istiod (profile ambient, licence, trustDomain, JSON logs),
#      then cni, then ztunnel (profile ambient, JSON logs, L7 telemetry)
# Idempotent. Needs docker, kind, kubectl, helm, gcloud (authenticated) and
# SOLO_ISTIO_LICENSE_KEY (export it, or point SECRETS_FILE at a file that does).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

require kind; require kubectl; require helm; require docker; require gcloud
check_docker; check_gcloud; require_secrets

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

step "Pre-pulling Solo Istio images ($ISTIO_VERSION) and loading into kind"
__tar_tmp="$(mktemp -d)"; trap 'rm -rf "$__tar_tmp"' EXIT
while read -r img; do
  docker image inspect "$img" >/dev/null 2>&1 || { log "pulling $img …"; docker pull --quiet "$img" >/dev/null; }
  tar="$__tar_tmp/$(echo "$img" | tr '/:' '__').tar"
  docker save --platform "$KIND_PLATFORM" "$img" -o "$tar"
  log "loading $(basename "$img") into kind …"
  kind load image-archive "$tar" --name "$CLUSTER_NAME" >/dev/null
  rm -f "$tar"
done < <(solo_istio_images)
ok "Solo Istio images loaded"

HREPO="$ISTIO_HELM_REPO"; HVER="$ISTIO_HELM_VERSION"

step "Helm: istio-base (CRDs + cluster roles)"
helm --kube-context "$CTX" upgrade -i istio-base "$HREPO/base" \
  -n "$ISTIO_SYSTEM_NS" --create-namespace --version "$HVER" \
  --set defaultRevision=default --wait >/dev/null
ok "istio-base installed"

step "Helm: istiod (profile ambient) — licence, trust domain, JSON logs as VALUES"
# Everything the operator hid is set here directly. No kubectl patch afterwards.
helm --kube-context "$CTX" upgrade -i istiod "$HREPO/istiod" \
  -n "$ISTIO_SYSTEM_NS" --version "$HVER" --wait -f - >/dev/null <<EOF
profile: ambient
global:
  hub: ${ISTIO_REGISTRY}
  tag: ${ISTIO_VERSION}
istio_cni:
  enabled: true
license:
  value: ${SOLO_ISTIO_LICENSE_KEY}
env:
  # custom (non cluster.local) trust domain -> skip peer trust-domain validation
  PILOT_SKIP_VALIDATE_TRUST_DOMAIN: "true"
meshConfig:
  accessLogFile: /dev/stdout
  # the mesh trust domain: identities become spiffe://${TRUST_DOMAIN}/ns/<ns>/sa/<sa>
  trustDomain: ${TRUST_DOMAIN}
EOF
kc -n "$ISTIO_SYSTEM_NS" rollout status deploy/istiod --timeout=180s >/dev/null
ok "istiod ready (ambient), licence + trustDomain '${TRUST_DOMAIN}' set as Helm values"

step "Helm: istio-cni (node traffic capture)"
helm --kube-context "$CTX" upgrade -i istio-cni "$HREPO/cni" \
  -n "$ISTIO_SYSTEM_NS" --version "$HVER" --wait -f - >/dev/null <<EOF
profile: ambient
global:
  hub: ${ISTIO_REGISTRY}
  tag: ${ISTIO_VERSION}
ambient:
  dnsCapture: true
excludeNamespaces:
  - istio-system
  - kube-system
EOF
ok "istio-cni installed"

step "Helm: ztunnel (per-node L4 proxy) — JSON access logs + L7 telemetry as VALUES"
helm --kube-context "$CTX" upgrade -i ztunnel "$HREPO/ztunnel" \
  -n "$ISTIO_SYSTEM_NS" --version "$HVER" --wait -f - >/dev/null <<EOF
profile: ambient
hub: ${ISTIO_REGISTRY}
tag: ${ISTIO_VERSION}
namespace: ${ISTIO_SYSTEM_NS}
istioNamespace: ${ISTIO_SYSTEM_NS}
env:
  # structured access logs with src.identity/dst.identity (no post-hoc patch)
  LOG_FORMAT: json
  # Solo L7 telemetry from ztunnel (HTTP metrics/logs) without a waypoint
  L7_ENABLED: "true"
EOF
kc -n "$ISTIO_SYSTEM_NS" rollout status daemonset/ztunnel --timeout=180s >/dev/null
kc -n "$ISTIO_SYSTEM_NS" rollout status daemonset/istio-cni-node --timeout=180s >/dev/null
ok "ztunnel + istio-cni running on every node, JSON access logs on"

echo
ok "Cluster ready. Solo Istio $ISTIO_VERSION (Helm, no operator) in AMBIENT mode, trust domain '${TRUST_DOMAIN}'."
log "Now follow the README: deploy the workloads, inspect the SVID, then apply the policies."
