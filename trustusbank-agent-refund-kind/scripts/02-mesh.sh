#!/usr/bin/env bash
# Install the Solo distribution on this lab's cluster only.
source "$(dirname "$0")/lib.sh"
set +x
source "${SECRETS_FILE:-$HOME/code/solo/secrets/secrets-envs.sh}" >/dev/null 2>&1
: "${SOLO_ISTIO_LICENSE_KEY:?Solo Istio licence required}"
cluster=trustusbank-lab
repo=oci://us-docker.pkg.dev/soloio-img/istio-helm
hub=us-docker.pkg.dev/soloio-img/istio
platform="linux/$(k get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}')"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for name in pilot proxyv2 install-cni ztunnel; do
  image="$hub/$name:$SOLO_ISTIO_VERSION-distroless"
  docker image inspect "$image" >/dev/null 2>&1 || docker pull "$image"
  docker image save --platform "$platform" -o "$tmp/image.tar" "$image"
  kind load image-archive "$tmp/image.tar" --name "$cluster"
done
helm --kube-context "$CTX" upgrade -i istio-base "$repo/base" -n istio-system --create-namespace --version "$SOLO_ISTIO_VERSION" --set defaultRevision=default --wait
# Retain the existing release names when upgrading the old bank cluster.
helm --kube-context "$CTX" upgrade -i istio-istiod "$repo/istiod" -n istio-system --version "$SOLO_ISTIO_VERSION" --wait --timeout=5m -f - <<EOF
profile: ambient
global:
  hub: $hub
  tag: $SOLO_ISTIO_VERSION
istio_cni:
  enabled: true
license:
  value: $SOLO_ISTIO_LICENSE_KEY
meshConfig:
  trustDomain: cluster.local
  accessLogFile: /dev/stdout
EOF
helm --kube-context "$CTX" upgrade -i istio-cni "$repo/cni" -n istio-system --version "$SOLO_ISTIO_VERSION" --wait --timeout=5m -f - <<EOF
profile: ambient
global:
  hub: $hub
  tag: $SOLO_ISTIO_VERSION
ambient:
  dnsCapture: true
excludeNamespaces: [istio-system, kube-system]
EOF
helm --kube-context "$CTX" upgrade -i istio-ztunnel "$repo/ztunnel" -n istio-system --version "$SOLO_ISTIO_VERSION" --wait --timeout=5m -f - <<EOF
profile: ambient
hub: $hub
tag: $SOLO_ISTIO_VERSION
namespace: istio-system
istioNamespace: istio-system
env:
  LOG_FORMAT: json
EOF
if [[ "$cluster" == trustusbank-lab ]]; then
  k label namespace bank istio.io/dataplane-mode=ambient --overwrite
  apply "$LAB/yaml/mesh.yaml"
fi
