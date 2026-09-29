#!/usr/bin/env bash
# Removes everything up.sh made. The GPUs and vllm belong to the model-routing
# lab and are left alone.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CTX="${KUBE_CONTEXT:-$(kubectl config get-contexts -o name | grep 'cluster/model-routing$' || kubectl config current-context)}"
files=("$HERE"/0*.yaml "$HERE"/0*.yaml.tmpl)
for ((i=${#files[@]}-1; i>=0; i--)); do
  kubectl --context "$CTX" delete -f "${files[$i]}" --ignore-not-found
done
# The decision gateway belongs to the task-routing lab and stays. Take back the role this
# lab lent it, before the role is deleted below: a service account annotated with a role
# that no longer exists fails every request the moment the pod restarts, which would break
# that lab rather than this one.
if kubectl --context "$CTX" -n agentgateway-system get sa decision-gateway >/dev/null 2>&1; then
  kubectl --context "$CTX" -n agentgateway-system annotate serviceaccount decision-gateway \
    eks.amazonaws.com/role-arn- >/dev/null 2>&1 || true
  kubectl --context "$CTX" -n agentgateway-system rollout restart deploy/decision-gateway >/dev/null 2>&1 || true
fi
aws iam delete-role-policy --role-name kernwerk-dlp-gateway --policy-name invoke-eu-model 2>/dev/null || true
aws iam delete-role --role-name kernwerk-dlp-gateway 2>/dev/null || true
echo "kernwerk dlp removed"
