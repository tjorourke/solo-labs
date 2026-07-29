#!/usr/bin/env bash
# setup-cluster.sh — stands up the SIDECAR starting posture, all upstream OSS:
#
#   1. kind cluster (1 control-plane + 2 workers) + Gateway API CRDs
#   2. Istio images pre-pulled on the host and kind-loaded
#   3. istio-base (CRDs) + istiod in plain SIDECAR mode
#
# Nothing ambient yet — no CNI node agent, no ztunnel. That arrives later
# (scripts/ambient-enable.sh), which is the whole point: this is the mesh a
# sidecar estate runs today. Idempotent. Needs docker, kind, kubectl, helm.
# No licence, no registry auth.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

require kind; require kubectl; require helm; require docker
check_docker

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

step "Helm: istio-base (CRDs)"
# shellcheck disable=SC2046
helm --kube-context "$CTX" upgrade -i istio-base $(helm_chart base) \
  -n "$ISTIO_SYSTEM_NS" --create-namespace --version "$HVER" \
  --set defaultRevision=default --wait >/dev/null
ok "istio-base installed"

step "Helm: istiod (plain SIDECAR mode)"
# shellcheck disable=SC2046
helm --kube-context "$CTX" upgrade -i istiod $(helm_chart istiod) \
  -n "$ISTIO_SYSTEM_NS" --version "$HVER" --wait -f - >/dev/null <<EOF
global:
  hub: ${ISTIO_REGISTRY}
  tag: ${ISTIO_VERSION}
meshConfig:
  accessLogFile: /dev/stdout
EOF
kc -n "$ISTIO_SYSTEM_NS" rollout status deploy/istiod --timeout=180s >/dev/null
ok "istiod ready (sidecar mode)"

echo
ok "Sidecar baseline up: Istio $ISTIO_VERSION (upstream OSS), no ambient components yet."
log "Next: kubectl apply -f yaml/00-namespaces.yaml -f yaml/10-apps/ -f yaml/20-policies-sidecar/"
