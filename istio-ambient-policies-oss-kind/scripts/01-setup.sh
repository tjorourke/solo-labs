#!/usr/bin/env bash
# 01-setup.sh: one kind cluster with upstream OSS Istio in AMBIENT mode:
#
#   1. kind cluster (1 control-plane + 2 workers) + Gateway API CRDs
#   2. istioctl, downloaded from the upstream GitHub release into .bin/
#   3. Istio images pre-pulled on the host and kind-loaded
#   4. helm: istio-base (CRDs), istiod (profile=ambient), istio-cni, ztunnel
#
# Ambient from the start: there is no sidecar injection anywhere in this lab.
# Idempotent. Needs docker, kind, kubectl, helm, curl. No licence, no auth.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require kind; require kubectl; require helm; require docker; require curl
check_docker

step "Creating kind cluster '$CLUSTER_NAME'"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  ok "cluster '$CLUSTER_NAME' already exists"
else
  show kind create cluster --name "$CLUSTER_NAME" --config "$LAB_ROOT/kind/cluster.yaml"
  ok "cluster '$CLUSTER_NAME' created"
fi
kc wait --for=condition=Ready nodes --all --timeout=120s >/dev/null

step "Installing Gateway API CRDs $GATEWAY_API_VERSION (a waypoint is a Gateway)"
show kc apply --server-side -f \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
ok "Gateway API CRDs installed"

step "istioctl $ISTIO_VERSION (upstream release, downloaded into .bin/)"
have="$("$LAB_BIN/istioctl" version --remote=false 2>/dev/null || true)"
if [[ "$have" == "$ISTIO_VERSION" ]]; then
  ok "istioctl $ISTIO_VERSION already in $LAB_BIN"
else
  mkdir -p "$LAB_BIN"
  tarball="istioctl-${ISTIO_VERSION}-${ISTIOCTL_OS}-${ISTIOCTL_ARCH}.tar.gz"
  show curl -sSfL -o "$LAB_BIN/$tarball" \
    "https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/${tarball}"
  tar -xzf "$LAB_BIN/$tarball" -C "$LAB_BIN" istioctl
  rm -f "$LAB_BIN/$tarball"
  chmod +x "$LAB_BIN/istioctl"
  ok "istioctl $("$LAB_BIN/istioctl" version --remote=false) in $LAB_BIN"
fi

step "Pre-pulling Istio images ($ISTIO_VERSION, upstream OSS) and loading into kind"
# Load via `docker save --platform | kind load image-archive`: with Docker's
# containerd image store, `kind load docker-image` fails ("content digest …
# not found") because it imports the whole multi-platform index.
__tar_tmp="$(mktemp -d)"; trap 'rm -rf "$__tar_tmp"' EXIT
while read -r img; do
  docker image inspect "$img" >/dev/null 2>&1 || { log "pulling $img …"; docker pull --quiet "$img" >/dev/null; }
  tar="$__tar_tmp/$(echo "$img" | tr '/:' '__').tar"
  docker save --platform "$KIND_PLATFORM" "$img" -o "$tar"
  log "loading $(basename "$img") into kind …"
  kind load image-archive "$tar" --name "$CLUSTER_NAME" >/dev/null
  rm -f "$tar"
done < <(istio_images)
ok "Istio images loaded"

HVER="$ISTIO_HELM_VERSION"

step "helm: istio-base (CRDs)"
# shellcheck disable=SC2046
show helm --kube-context "$CTX" upgrade -i istio-base $(helm_chart base) \
  -n "$ISTIO_SYSTEM_NS" --create-namespace --version "$HVER" \
  --set defaultRevision=default --wait
ok "istio-base installed"

step "helm: istiod with profile=ambient"
# shellcheck disable=SC2046
show helm --kube-context "$CTX" upgrade -i istiod $(helm_chart istiod) \
  -n "$ISTIO_SYSTEM_NS" --version "$HVER" --wait \
  --set profile=ambient \
  --set global.hub="$ISTIO_REGISTRY" \
  --set global.tag="$ISTIO_VERSION" \
  --set meshConfig.accessLogFile=/dev/stdout
kc -n "$ISTIO_SYSTEM_NS" rollout status deploy/istiod --timeout=180s >/dev/null
ok "istiod ready (ambient profile)"

step "helm: istio-cni (the node agent that redirects enrolled pods to ztunnel)"
# shellcheck disable=SC2046
show helm --kube-context "$CTX" upgrade -i istio-cni $(helm_chart cni) \
  -n "$ISTIO_SYSTEM_NS" --version "$HVER" --wait \
  --set profile=ambient \
  --set global.hub="$ISTIO_REGISTRY" \
  --set global.tag="$ISTIO_VERSION"
kc -n "$ISTIO_SYSTEM_NS" rollout status daemonset/istio-cni-node --timeout=180s >/dev/null
ok "istio-cni running on every node"

step "helm: ztunnel (the per-node L4 proxy)"
# shellcheck disable=SC2046
show helm --kube-context "$CTX" upgrade -i ztunnel $(helm_chart ztunnel) \
  -n "$ISTIO_SYSTEM_NS" --version "$HVER" --wait \
  --set profile=ambient \
  --set hub="$ISTIO_REGISTRY" \
  --set tag="$ISTIO_VERSION" \
  --set env.LOG_FORMAT=json
kc -n "$ISTIO_SYSTEM_NS" rollout status daemonset/ztunnel --timeout=180s >/dev/null
ok "ztunnel running on every node"

echo
show kc -n "$ISTIO_SYSTEM_NS" get pods -o wide
echo
ok "Ambient mesh up: Istio $ISTIO_VERSION (upstream OSS). Nothing is enrolled yet."
log "Next: ./scripts/02-deploy-apps.sh"
