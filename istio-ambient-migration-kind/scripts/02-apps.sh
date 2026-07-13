#!/usr/bin/env bash
# 02-apps.sh — deploy the petstore app in SIDECAR mode and its sidecar-era
# policies, plus the classic Istio ingress gateway.
#
#   1. Istio ingress gateway (istio `gateway` Helm chart) in istio-ingress,
#      NodePort 30080/30443, injected → runs the Solo proxy image.
#   2. App namespaces + workloads (catalog v1/v2, redis, data-client, checkout,
#      fortio) — every pod gets a sidecar.
#   3. Sidecar-era policies: STRICT mTLS, catalog DR+VS (subset canary), L4 authz
#      on redis, L7 authz on catalog, and the ingress Gateway+VirtualService.
# Idempotent.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

require kubectl; require helm

GATEWAY_CHART="${GATEWAY_CHART:-oci://us-docker.pkg.dev/soloio-img/istio-helm/gateway}"

step "Installing Istio ingress gateway in $NS_INGRESS"
kc create namespace "$NS_INGRESS" >/dev/null 2>&1 || true
kc label namespace "$NS_INGRESS" istio-injection=enabled --overwrite >/dev/null
helm --kube-context "$CTX" upgrade --install istio-ingressgateway "$GATEWAY_CHART" \
  --namespace "$NS_INGRESS" \
  --version "$SOLO_ISTIO_VERSION" \
  --set labels.istio=ingressgateway \
  --set service.type=NodePort \
  --set 'service.ports[0].name=http2' \
  --set 'service.ports[0].port=80' \
  --set 'service.ports[0].targetPort=80' \
  --set 'service.ports[0].nodePort=30080' \
  --set 'service.ports[1].name=https' \
  --set 'service.ports[1].port=443' \
  --set 'service.ports[1].targetPort=443' \
  --set 'service.ports[1].nodePort=30443' \
  --wait --timeout 3m >/dev/null
ok "ingress gateway installed"

step "Deploying petstore workloads (sidecar mode)"
kapply "$LAB_ROOT/yaml/10-apps-sidecar/00-namespaces.yaml"
kapply "$LAB_ROOT/yaml/10-apps-sidecar/10-catalog.yaml"
kapply "$LAB_ROOT/yaml/10-apps-sidecar/20-data.yaml"
kapply "$LAB_ROOT/yaml/10-apps-sidecar/30-legacy.yaml"
for d in "petstore catalog-v1" "petstore catalog-v2" "petstore data-client" \
         "petstore-data redis" "petstore-legacy checkout" "petstore-legacy fortio"; do
  set -- $d; wait_deploy "$1" "$2" || true
done
ok "workloads ready"

step "Applying sidecar-era policies"
kapply "$LAB_ROOT/yaml/20-policies-sidecar/00-peerauth-strict.yaml"
kapply "$LAB_ROOT/yaml/20-policies-sidecar/10-catalog-dr-vs.yaml"
kapply "$LAB_ROOT/yaml/20-policies-sidecar/20-l4-authz-data.yaml"
kapply "$LAB_ROOT/yaml/20-policies-sidecar/30-l7-authz-catalog.yaml"
kapply "$LAB_ROOT/yaml/10-apps-sidecar/50-ingress.yaml"
ok "policies + ingress route applied"

echo
ok "Petstore running in SIDECAR mode. Every pod has 2/2 containers (app + istio-proxy)."
log "verify:  kubectl --context $CTX get pods -n petstore"
log "next:    ./scripts/03-flip-ambient.sh"
