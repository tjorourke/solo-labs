#!/usr/bin/env bash
# kagent and the three agents.
#
#   ./scripts/04-kagent.sh
#
# OSS kagent, no OIDC and no AgentRegistry. Agent creation is unrestricted here, so
# these apply directly; a cluster that reserves it to the control plane needs
#   --as=system:serviceaccount:kagent:kagent-controller
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

KAGENT_VERSION="${KAGENT_VERSION:-0.9.1}"

banner "kagent CRDs $KAGENT_VERSION"
helm_ upgrade --install kagent-crds oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds \
  --namespace kagent --create-namespace --version "$KAGENT_VERSION" --wait >/dev/null

banner "kagent $KAGENT_VERSION"
# providers.default=openAI with a dummy key: every ModelConfig in this lab points at the
# gateway, so kagent never talks to OpenAI. The chart still wants a provider set.
helm_ upgrade --install kagent oci://ghcr.io/kagent-dev/kagent/helm/kagent \
  --namespace kagent --version "$KAGENT_VERSION" \
  --set providers.openAI.apiKey="not-used-in-cluster" \
  --wait --timeout 5m >/dev/null
kubectl -n kagent rollout status deploy/kagent-controller --timeout=300s

banner "the three agents"
kubectl apply -f "$HERE/yaml/40-kagent-modelconfig.yaml"
kubectl apply -f "$HERE/yaml/50-kagent-agent.yaml"
kubectl apply -f "$HERE/yaml/60-kagent-specialist-agents.yaml"

banner "waiting for them"
for a in routing-demo finance-analyst coding-assistant; do
  kubectl -n kagent rollout status "deploy/$a" --timeout=300s || true
done
kubectl get agents -n kagent
