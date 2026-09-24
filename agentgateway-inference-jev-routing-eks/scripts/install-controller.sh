#!/usr/bin/env bash
# Reader-invoked setup for the disposable kind cluster only. Never targets EKS.
set -euo pipefail
: "${KUBECONFIG:?Set KUBECONFIG to the disposable cluster's kubeconfig}"
: "${KUBE_CONTEXT:?Set KUBE_CONTEXT=kind-jev-routing-kb}"
[[ "$KUBE_CONTEXT" == "kind-jev-routing-kb" ]] || {
  printf 'This installer is restricted to kind-jev-routing-kb.\n' >&2
  exit 1
}
edition="${1:?Usage: bash scripts/install-controller.sh oss|enterprise}"
case "$edition" in
  oss)
    chart=oci://cr.agentgateway.dev/charts
    release=agentgateway
    version=v1.5.0
    licence=()
    ;;
  enterprise)
    : "${AGENTGATEWAY_LICENSE_KEY:?Set the Solo Enterprise licence key}"
    chart=oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts
    release=enterprise-agentgateway
    version=v2026.9.0
    licence=(--set-string "licensing.licenseKey=$AGENTGATEWAY_LICENSE_KEY")
    ;;
  *) printf 'Choose oss or enterprise.\n' >&2; exit 1 ;;
esac
kubectl --context "$KUBE_CONTEXT" apply --server-side \
  -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/experimental-install.yaml
helm --kube-context "$KUBE_CONTEXT" upgrade --install "${release}-crds" "$chart/${release}-crds" \
  --namespace agentgateway-system --create-namespace --version "$version" --wait --timeout 5m
helm --kube-context "$KUBE_CONTEXT" upgrade --install "$release" "$chart/$release" \
  --namespace agentgateway-system --version "$version" \
  --set-string controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true \
  "${licence[@]}" --wait --timeout 5m
kubectl --context "$KUBE_CONTEXT" wait \
  --for=jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'=True \
  "gatewayclass/$release" --timeout=180s
