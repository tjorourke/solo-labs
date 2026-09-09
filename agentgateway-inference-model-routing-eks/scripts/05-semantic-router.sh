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

banner() { echo; echo "==> $*"; }

VSR_VERSION="${VSR_VERSION:-v0.0.0-latest}"

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
