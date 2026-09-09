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
if [ -n "${KUBE_CONTEXT:-}" ]; then
  CTX="$KUBE_CONTEXT"
elif [ -n "${EKS_CLUSTER:-}" ]; then
  REGION="${AWS_REGION:-eu-west-2}"
  ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
  [ -n "$ACCOUNT" ] && [ "$ACCOUNT" != "None" ] \
    || { echo "error: no AWS identity. Check AWS_PROFILE, or run aws sso login." >&2; exit 1; }
  CTX="arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${EKS_CLUSTER}"
else
  CTX="$(kubectl config current-context 2>/dev/null)"
  [ -n "$CTX" ] || { echo "error: no current kubectl context, and neither KUBE_CONTEXT nor EKS_CLUSTER is set." >&2; exit 1; }
fi
kubectl() { command kubectl --context "$CTX" "$@"; }
helm_()   { helm --kube-context "$CTX" "$@"; }

GWAPI_VERSION="${GWAPI_VERSION:-v1.4.0}"
AGW_VERSION="${AGW_VERSION:-v1.3.0-alpha.1}"
NS=agentgateway-system

banner() { echo; echo "==> $*"; }

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
