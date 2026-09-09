#!/usr/bin/env bash
# Install OSS agentgateway and the Gateway API it needs.
#
#   ./scripts/01-gateway.sh
#
# THE EXPERIMENTAL CHANNEL IS NOT OPTIONAL. ExtProc rides on Gateway API experimental
# features, and the standard channel does not carry them. Install the standard channel
# and the semantic router step later fails with the policy Accepted and nothing
# happening, which is a bad way to find out.
#
# --server-side is needed too: the experimental CRDs carry a last-applied annotation
# that blows past the 256KB client-side apply limit ("metadata.annotations: Too long").
set -euo pipefail

# The lab root, so the script works from anywhere.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Cluster selection: current context by default, KUBE_CONTEXT to name one, or
# EKS_CLUSTER for the cloud case where the context name is an ARN nobody types.
. "$HERE/scripts/lib-context.sh"
resolve_ctx
kubectl() { command kubectl --context "$CTX" "$@"; }
helm_()   { helm --kube-context "$CTX" "$@"; }

GWAPI_VERSION="${GWAPI_VERSION:-v1.4.0}"
AGW_VERSION="${AGW_VERSION:-v1.3.0-alpha.1}"
NS=agentgateway-system

banner() { echo; echo "==> $*"; }

# eksctl marks no default StorageClass, and the in-tree gp2 class it leaves behind is not
# default either. Anything that does not name a class then sits Pending on "no storage
# class is set" - kagent's bundled Postgres does exactly that, and the kagent controller
# crash-loops against a database whose volume never arrives. Mark one before anything
# needs it.
banner "default StorageClass"
kubectl apply -f "$HERE/yaml/02-default-storageclass.yaml"

banner "Gateway API $GWAPI_VERSION, experimental channel"
kubectl apply --server-side --force-conflicts \
  -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GWAPI_VERSION}/experimental-install.yaml" >/dev/null
echo "    applied"

banner "agentgateway CRDs $AGW_VERSION"
helm_ upgrade --install agentgateway-crds \
  oci://cr.agentgateway.dev/charts/agentgateway-crds \
  --namespace "$NS" --create-namespace \
  --version "$AGW_VERSION" --wait >/dev/null
echo "    installed"

banner "agentgateway control plane $AGW_VERSION"
# KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES is the other half of the experimental
# channel: the CRDs exist without it, and the controller ignores them.
helm_ upgrade --install agentgateway \
  oci://cr.agentgateway.dev/charts/agentgateway \
  --namespace "$NS" \
  --version "$AGW_VERSION" \
  --set controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true \
  --wait --timeout 5m >/dev/null
echo "    installed"

# The GatewayClass being Accepted is the real readiness signal, since yaml/05 selects it
# by name. A Deployment that is Running but whose class is not Accepted yet produces a
# Gateway that never programs.
banner "waiting for the agentgateway GatewayClass"
kubectl wait --for=jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'=True \
  gatewayclass/agentgateway --timeout=180s

banner "done"
kubectl get gatewayclass
kubectl -n "$NS" get pods
