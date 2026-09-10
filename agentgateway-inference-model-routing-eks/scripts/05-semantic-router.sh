#!/usr/bin/env bash
# The vLLM Semantic Router, and the policy that hands it the decision.
#
#   ./scripts/05-semantic-router.sh
#
# First start downloads the classifier weights, a few GB, so allow ten minutes.
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

# Pinned. Upstream also publishes a rolling v0.0.0-latest chart, and a chart that drifts
# ahead of the v0.3 config in yaml/70 can ignore it without an error and start as a no-op
# router. yaml/70 pins the image by digest for the same reason.
VSR_VERSION="${VSR_VERSION:-0.3.0}"

banner "semantic router $VSR_VERSION"
helm_ upgrade --install semantic-router \
  oci://ghcr.io/vllm-project/charts/semantic-router \
  -n agentgateway-system --version "$VSR_VERSION" \
  -f "$HERE/yaml/70-semantic-router-values.yaml" >/dev/null

banner "waiting for it to download its classifier models"
kubectl -n agentgateway-system rollout status deploy/semantic-router --timeout=1800s

banner "handing it the decision"
kubectl apply -f "$HERE/yaml-oss/80-semantic-router-extproc.yaml"
kubectl apply -f "$HERE/yaml-oss/81-httproute-vsr.yaml"

echo
echo "semantic classification is now applied. Back to the keyword classifier with:"
echo "  kubectl apply -f yaml-oss/20-routing-policy.yaml -f yaml-oss/30-httproute.yaml"
