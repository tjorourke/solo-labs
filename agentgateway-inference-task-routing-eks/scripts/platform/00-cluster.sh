#!/usr/bin/env bash
# Platform step 1: the EKS cluster, one GPU node.
#
#   ./scripts/platform/00-cluster.sh
#
# Creates eks/cluster.yaml with eksctl if the cluster is not there, refreshes the kubeconfig
# entry, installs the EKS addons from the config, and scales the GPU nodegroup to one node.
# Skipped where already done. The NVIDIA device plugin eksctl would bundle is turned off
# here and installed by the next step instead, with time-slicing.
#
# About 20 minutes on a fresh account, the GPU node last. If the nodegroup sits CREATING for
# half an hour and rolls back, EC2 had no g7e.2xlarge capacity in the AZ; gpu.sh prints the
# Auto Scaling group's message, which names an AZ that has stock.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
set -euo pipefail
EKS_CLUSTER="${EKS_CLUSTER:-model-routing}"; AWS_REGION="${AWS_REGION:-eu-west-2}"
export EKS_CLUSTER AWS_REGION
banner() { echo; echo "==> $*"; }

banner "cluster $EKS_CLUSTER in $AWS_REGION"
if aws eks describe-cluster --region "$AWS_REGION" --name "$EKS_CLUSTER" >/dev/null 2>&1; then
  echo "    exists, skipping create"
else
  echo "    creating from eks/cluster.yaml"
  eksctl create cluster -f "$HERE/eks/cluster.yaml" --install-nvidia-plugin=false
  kubectl create configmap lab-owner -n kube-system --from-literal=lab=agentgateway-inference-task-routing-eks \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
fi
# A rebuilt cluster keeps its name and changes endpoint; a stale context fails with no such host.
aws eks update-kubeconfig --region "$AWS_REGION" --name "$EKS_CLUSTER" >/dev/null
. "$HERE/scripts/lib.sh"

banner "EKS addons from eks/cluster.yaml"
# Idempotent. An eksctl create that gave up waiting on the GPU nodegroup skips the addons, and
# without the EBS CSI driver every volume in the cluster sits Pending.
eksctl create addon -f "$HERE/eks/cluster.yaml" 2>&1 | grep -E "creating addon|active|already present" | sed 's/^.*\] */    /'

banner "default StorageClass"
kubectl apply -f "$HERE/yaml/platform/00-default-storageclass.yaml"

banner "GPU nodegroup at one node"
desired="$(aws eks describe-nodegroup --region "$AWS_REGION" --cluster-name "$EKS_CLUSTER" --nodegroup-name gpu \
  --query 'nodegroup.scalingConfig.desiredSize' --output text)"
if [ "$desired" != "1" ]; then "$HERE/scripts/platform/gpu.sh" up; else echo "    desired=1"; fi
kubectl get nodes -L role -o custom-columns='NODE:.metadata.name,ROLE:.metadata.labels.role,READY:.status.conditions[-1].status,ZONE:.metadata.labels.topology\.kubernetes\.io/zone'
echo
echo "Next: ./scripts/platform/10-agentgateway.sh"
