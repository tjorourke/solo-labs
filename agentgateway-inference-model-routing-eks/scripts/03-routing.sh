#!/usr/bin/env bash
# The gateway, a backend per model, the PreRouting policy and the route.
#
#   ./scripts/03-routing.sh
#
# Uses the OSS CRDs in yaml-oss/. The Enterprise set in yaml/ is the same shape with
# an Enterprise prefix on the kinds and a different gatewayClassName.
set -euo pipefail

# The lab root, so the script works from anywhere.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Cluster selection: current context by default, KUBE_CONTEXT to name one, or
# EKS_CLUSTER for the cloud case where the context name is an ARN nobody types.
. "$HERE/scripts/lib-context.sh"
resolve_ctx
kubectl() { command kubectl --context "$CTX" "$@"; }
helm_()   { helm --kube-context "$CTX" "$@"; }

banner() { echo; echo "==> $*"; }

banner "gateway"
kubectl apply -f "$HERE/yaml/05-gateway.yaml"
kubectl wait --for=condition=Programmed gateway/model-gateway -n agentgateway-system --timeout=180s

banner "backends, policy and route"
kubectl apply -f "$HERE/yaml-oss/10-backends.yaml"
kubectl apply -f "$HERE/yaml-oss/20-routing-policy.yaml"
kubectl apply -f "$HERE/yaml-oss/30-httproute.yaml"

# Accepted and Attached matter. A policy that fails to attach leaves the header unset,
# no rule matches, and every request quietly serves the default model with a 200.
banner "attachment status"
kubectl get agentgatewaybackends,agentgatewaypolicies -n agentgateway-system
kubectl get httproute -n agentgateway-system
