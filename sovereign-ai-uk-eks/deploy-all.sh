#!/usr/bin/env bash
# The whole environment, from an empty AWS account to a defended, sovereign model with
# agents, in one command. Infrastructure as code end to end: the cluster and all three
# node groups are the eksctl config, everything above is versioned YAML and Helm values,
# and this script runs the layers in the one order that works.
#
#   SOVEREIGN_AWS_PROFILE=<profile> SOVEREIGN_ENV_FILE=<licences.env> ./deploy-all.sh
#   ./deploy-all.sh <phase>        run a single phase (see the list below)
#   ./deploy-all.sh phases         list the phases
#
# Nothing secret lives in the repo. The AWS account id and the weights bucket are derived
# at run time from the profile in effect, and the Solo licence keys are read from your
# environment (or SOVEREIGN_ENV_FILE), never committed.
#
# Every phase is idempotent, so a re-run after a failure picks up rather than starting
# again. The GPU meter ($5.84/hr) starts at the 'gpu' phase; everything before it is cheap.
set -euo pipefail

export SOVEREIGN_AWS_PROFILE="${SOVEREIGN_AWS_PROFILE:?set SOVEREIGN_AWS_PROFILE to your AWS SSO profile}"
export AWS_PROFILE="$SOVEREIGN_AWS_PROFILE"
REGION=eu-west-2
CLUSTER=uk-sovereign-ai
LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$LAB"

ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
[ -n "$ACCOUNT" ] && [ "$ACCOUNT" != "None" ] || { echo "error: no AWS identity; check SOVEREIGN_AWS_PROFILE (SSO login expired?)" >&2; exit 1; }
CTX="arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${CLUSTER}"

banner() { echo; echo "════════ $* ════════"; }

# ---- phases, in order ----
p_cluster() {
  banner "cluster: VPC, and all three node groups (platform, gpu-od, sandbox)"
  if aws eks describe-cluster --region "$REGION" --name "$CLUSTER" >/dev/null 2>&1; then
    echo "cluster exists; ensuring node groups"
    for ng in platform gpu-od sandbox; do
      aws eks describe-nodegroup --region "$REGION" --cluster-name "$CLUSTER" --nodegroup-name "$ng" >/dev/null 2>&1 \
        || eksctl create nodegroup -f eks/cluster.yaml --include="$ng"
    done
  else
    eksctl create cluster -f eks/cluster.yaml
  fi
}
p_model()  { banner "model: network policy, storage, IRSA, GPU, weights, vLLM"
  for s in cni gpu-plugin storage iam gpu weights vllm; do ./scripts/e2e.sh "$s"; done; }
p_ca()     { banner "certificate authority + mesh (Vault installs cert-manager it needs)"
  ./scripts/vault.sh up; ./scripts/istio-csr.sh up; }
p_idp()    { banner "identity provider"; ./scripts/keycloak.sh up; }
p_gateway(){ banner "gateway + TLS on the edge"; ./scripts/agentgateway.sh up; ./scripts/tls.sh up; }
p_enrol()  { banner "enrol the workloads in the mesh"; ./scripts/ambient.sh enrol; }
p_policy() { banner "admission policy (PSA + Kyverno)"; ./scripts/policy.sh up; }
p_obs()    { banner "observability + alerting (Prometheus, Grafana, Alertmanager, Mailpit)"; ./scripts/observability.sh up; }
p_substrate(){ banner "gVisor on the sandbox node group"; ./scripts/substrate.sh up; }
p_kagent() { banner "kagent runtime (OIDC to Keycloak)"; ./scripts/kagent.sh up; }
p_verify() { banner "verify: Mistral answers, over TLS, through the gateway"; ./scripts/ask.sh "what city are you running in?"; }

PHASES=(cluster model ca idp gateway enrol policy obs substrate kagent verify)

case "${1:-all}" in
  phases) printf '%s\n' "${PHASES[@]}" ;;
  all)
    for p in "${PHASES[@]}"; do "p_${p}"; done
    banner "done"
    echo "Everything is up. Stop the GPU meter when you finish for the day:  ./scripts/gpu.sh down"
    echo "Fire the alert-email demo:  ./scripts/observability.sh alert   then   ./scripts/observability.sh mail"
    ;;
  *)
    fn="p_${1}"
    declare -F "$fn" >/dev/null || { echo "unknown phase '$1'. try: ${PHASES[*]}" >&2; exit 1; }
    "$fn"
    ;;
esac
