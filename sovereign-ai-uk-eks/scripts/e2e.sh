#!/usr/bin/env bash
# The whole build, in the one order that works, from an empty account to a chat
# completion answered by Mistral through agentgateway.
#
#   ./scripts/e2e.sh            run every stage, skipping what is already done
#   ./scripts/e2e.sh <stage>    run one stage (cluster|cni|gpu-plugin|storage|iam|gpu|weights|vllm|agw|route|verify)
#   ./scripts/e2e.sh stages     list the stages
#
# Each stage is idempotent, so a re-run after a failure picks up rather than starting
# again. That matters here because the expensive stages are the 48 GB restore and the
# vLLM load, and both happen with a $5.84/hr GPU node up.
#
# The order is not arbitrary and four steps are counter-intuitive. Each one is
# commented at the point it matters rather than in a preamble nobody reads, because an
# earlier version of the written sequence had all four wrong and every one of them
# stalls the build with no error that points at the cause.
set -euo pipefail

export AWS_PROFILE="${SOVEREIGN_AWS_PROFILE:?set SOVEREIGN_AWS_PROFILE to the sandbox SSO profile}"
REGION=eu-west-2
CLUSTER=uk-sovereign-ai
MODELS_NS=models
NVIDIA_PLUGIN_VERSION="${NVIDIA_PLUGIN_VERSION:-v0.19.3}"
LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
[ -n "$ACCOUNT" ] && [ "$ACCOUNT" != "None" ] || { echo "error: no AWS identity; check SOVEREIGN_AWS_PROFILE" >&2; exit 1; }
CTX="arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${CLUSTER}"
kubectl() { command kubectl --context "$CTX" "$@"; }

step() { echo; echo "── $* ─────────────────────────────────────────────"; }
ok()   { echo "   ok: $*"; }
skip() { echo "   already done: $*"; }

s_cluster() {
  step "EKS cluster $CLUSTER (~20 min)"
  if aws eks describe-cluster --region "$REGION" --name "$CLUSTER" >/dev/null 2>&1; then
    skip "cluster exists"; return
  fi
  eksctl create cluster -f "$LAB_ROOT/eks/cluster.yaml"
  ok "cluster created"
}

s_cni() {
  step "vpc-cni: enable NetworkPolicy without breaking the CNI"
  # Look the role up, NEVER paste a remembered ARN. eksctl mints this role fresh on
  # every cluster create with a new random suffix, so yesterday's ARN belongs to a
  # deleted cluster. Omitting it, or passing a stale one, nulls the addon's
  # serviceAccountRoleArn and strips the role annotation off the aws-node
  # ServiceAccount. ipamd then falls back to node-instance-role credentials that lack
  # AmazonEKS_CNI_Policy, DescribeNetworkInterfaces 403s, the socket is never served
  # and aws-eks-nodeagent crashloops on connection refused. Nothing in kubectl output
  # mentions IAM. This one line cost an afternoon.
  local role
  role="$(aws eks describe-addon --region "$REGION" --cluster-name "$CLUSTER" \
    --addon-name vpc-cni --query 'addon.serviceAccountRoleArn' --output text 2>/dev/null)"

  # A None here mid-create is normal and is NOT the outage. eksctl creates addons
  # before it associates the OIDC provider, warns "recommended policies were found ...
  # but since OIDC is disabled", and then fixes it up near the end of the create in its
  # "update VPC CNI to use IRSA" step, which deploys an addon-vpc-cni stack and sets
  # the role. Measured on the 2026-08-12 rebuild: None at 08:27, a real role by 08:28.
  # So do not run this stage against a create that is still in flight, and do not read
  # the warning as damage.
  #
  # The branch below is a safety net for a cluster that genuinely has no role: an older
  # eksctl, a cluster built by hand, or an addon someone reinstalled without one.
  # Enabling NetworkPolicy against a null role is what strips the aws-node annotation
  # and takes ipamd down, and nothing in kubectl output points at IAM when it happens.
  if [ -z "$role" ] || [ "$role" = "None" ]; then
    echo "   no IRSA role on the addon; minting one (if the create is still running, wait instead)"
    eksctl create iamserviceaccount --cluster "$CLUSTER" --region "$REGION" \
      --namespace kube-system --name aws-node \
      --attach-policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy \
      --override-existing-serviceaccounts --approve
    role="$(kubectl -n kube-system get sa aws-node \
      -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || echo '')"
    [ -n "$role" ] || { echo "   error: could not mint an aws-node IRSA role, STOP" >&2; exit 1; }
  fi
  echo "   role: $role"

  local cur
  cur="$(aws eks describe-addon --region "$REGION" --cluster-name "$CLUSTER" \
    --addon-name vpc-cni --query 'addon.configurationValues' --output text 2>/dev/null || echo '')"
  if [[ "$cur" == *'"enableNetworkPolicy":"true"'* ]]; then
    skip "NetworkPolicy already enabled"
  else
    aws eks update-addon --region "$REGION" --cluster-name "$CLUSTER" \
      --addon-name vpc-cni --service-account-role-arn "$role" \
      --configuration-values '{"enableNetworkPolicy":"true"}' --resolve-conflicts OVERWRITE >/dev/null
    aws eks wait addon-active --region "$REGION" --cluster-name "$CLUSTER" --addon-name vpc-cni
    ok "NetworkPolicy enabled"
  fi

  # Assert the thing that actually breaks, rather than trusting the update.
  local ann
  ann="$(kubectl -n kube-system get sa aws-node \
    -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || echo '')"
  [ -n "$ann" ] || { echo "   error: aws-node SA lost its role annotation, the CNI is about to break" >&2; exit 1; }
  ok "aws-node still carries $ann"
}

s_gpu_plugin() {
  step "NVIDIA device plugin"
  # Without this, nvidia.com/gpu is never advertised, the vLLM pod sits Pending on an
  # otherwise healthy 4-GPU node, and gpu.sh up times out waiting for a resource that
  # nothing is publishing. eksctl installs it for GPU nodegroups on some AMI families
  # and not others, so this checks rather than assumes.
  if kubectl -n kube-system get ds nvidia-device-plugin-daemonset >/dev/null 2>&1 \
     || kubectl -n kube-system get ds nvidia-device-plugin >/dev/null 2>&1; then
    skip "device plugin daemonset present"; return
  fi
  kubectl apply -f "https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/${NVIDIA_PLUGIN_VERSION}/deployments/static/nvidia-device-plugin.yml"
  kubectl -n kube-system rollout status ds/nvidia-device-plugin-daemonset --timeout=300s
  ok "device plugin $NVIDIA_PLUGIN_VERSION installed"
}

s_storage() {
  step "namespace, gp3-fast StorageClass, weights PVC"
  # BEFORE the service account: this is what creates the models namespace, and eksctl
  # cannot put a ServiceAccount into a namespace that does not exist yet.
  kubectl apply -f "$LAB_ROOT/yaml/00-storage.yaml"
  ok "applied (PVC stays Pending until a GPU node exists, that is WaitForFirstConsumer)"
}

s_iam() {
  step "model-restore service account (read-only on the weights bucket)"
  # model-restore, NOT model-sync. 39- names model-restore, and model-sync is the
  # write-capable identity for a fresh Hugging Face pull, which a rebuild never does.
  # Read-only on purpose: the restore path has no business being able to overwrite the
  # master copy of the weights.
  if kubectl -n "$MODELS_NS" get sa model-restore >/dev/null 2>&1; then
    skip "model-restore exists"; return
  fi
  eksctl create iamserviceaccount --cluster "$CLUSTER" --region "$REGION" \
    --namespace "$MODELS_NS" --name model-restore \
    --attach-policy-arn "arn:aws:iam::${ACCOUNT}:policy/uk-sovereign-ai-model-s3-readonly" \
    --approve
  ok "model-restore created"
}

s_gpu() {
  step "GPU node up (\$5.84/hr starts here)"
  # BEFORE the restore, which reads backwards but is required twice over: the restore
  # Job selects role=gpu, and gp3-fast is WaitForFirstConsumer so the PVC cannot even
  # bind until a node exists in the right AZ. Skip this and the Job sits Pending with
  # nothing in its events pointing at the cause.
  SOVEREIGN_AWS_PROFILE="$AWS_PROFILE" "$LAB_ROOT/scripts/gpu.sh" up
}

s_weights() {
  step "restore 48 GB of weights from S3 in eu-west-2"
  if kubectl -n "$MODELS_NS" get job model-restore >/dev/null 2>&1; then
    skip "restore Job exists (delete it to re-run)"
  else
    # Through sed, never directly: the bucket name embeds the account id, which is a
    # placeholder because this file is published. Applied raw it targets a bucket
    # literally named ...-<AWS_ACCOUNT_ID> and 404s.
    sed "s/<AWS_ACCOUNT_ID>/${ACCOUNT}/" "$LAB_ROOT/yaml/39-model-restore-job.yaml" \
      | kubectl apply -f -
    ok "Job applied"
  fi
  echo "   waiting for the restore (48 GB, ~6-10 min)..."
  kubectl -n "$MODELS_NS" wait --for=condition=complete job/model-restore --timeout=45m
  kubectl -n "$MODELS_NS" logs job/model-restore --tail=12
  ok "weights on the PVC, and Hugging Face was never contacted"
}

s_vllm() {
  step "vLLM serving Mistral across 4x L4"
  kubectl apply -f "$LAB_ROOT/yaml/20-vllm.yaml"
  echo "   waiting for Ready (weight load + CUDA graph capture, ~5-8 min)..."
  kubectl -n "$MODELS_NS" rollout status deploy/vllm --timeout=20m
  # Prove the model answers BEFORE any gateway is in the path. If this is broken,
  # every gateway symptom afterwards is a red herring.
  kubectl -n "$MODELS_NS" run vllm-direct-probe --rm -i --restart=Never --image=curlimages/curl:8.11.1 -- \
    curl -sS --max-time 120 -X POST http://vllm.models.svc.cluster.local:8000/v1/chat/completions \
      -H 'content-type: application/json' \
      -d '{"model":"mistral-small-3.2-24b","max_tokens":40,"messages":[{"role":"user","content":"Reply with exactly: sovereign"}]}'
  echo
  ok "vLLM answers directly"
}

s_agw() {
  step "Enterprise agentgateway"
  SOVEREIGN_AWS_PROFILE="$AWS_PROFILE" "$LAB_ROOT/scripts/agentgateway.sh" up
}

s_route() {
  step "Gateway, LLM backend and route"
  SOVEREIGN_AWS_PROFILE="$AWS_PROFILE" "$LAB_ROOT/scripts/agentgateway.sh" route
}

s_verify() {
  step "the actual goal: Mistral, in London, through the gateway"
  SOVEREIGN_AWS_PROFILE="$AWS_PROFILE" "$LAB_ROOT/scripts/agentgateway.sh" test
}

STAGES=(cluster cni gpu-plugin storage iam gpu weights vllm agw route verify)

case "${1:-all}" in
  stages) printf '%s\n' "${STAGES[@]}" ;;
  all)
    for s in "${STAGES[@]}"; do "s_${s//-/_}"; done
    echo
    echo "══ done. Remember: ./scripts/gpu.sh down when you stop for the day."
    ;;
  *)
    fn="s_${1//-/_}"
    declare -F "$fn" >/dev/null || { echo "unknown stage '$1'. try: ${STAGES[*]}" >&2; exit 1; }
    "$fn"
    ;;
esac
