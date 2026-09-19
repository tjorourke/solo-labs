#!/usr/bin/env bash
# The cluster, agentgateway, and the NVIDIA device plugin.
#
#   ./scripts/01-cluster.sh
#
# Three things, each skipped when already there:
#   1. the EKS cluster. Part 1's cluster if it exists, otherwise eks/cluster.yaml, which is
#      Part 1's, with two nodes in the gpu nodegroup. A marker ConfigMap records that this
#      lab built it, so quick.sh teardown knows whether the cluster is its to delete.
#   2. OSS agentgateway v1.5.0 with the Gateway API experimental channel. Part 1 was
#      validated on v1.3.0-alpha.1; this part uses jwtAuthentication and extAuth at
#      PreRouting, which is the v1.5 line.
#   3. the NVIDIA device plugin, from its Helm chart, handing out whole cards. Each GPU
#      node advertises nvidia.com/gpu: 1, so the scheduler puts one model on each and
#      every model has the whole 96 GB. Sharing one card between them halves the memory
#      and, with it, the context window each model can serve.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -euo pipefail
EKS_CLUSTER="${EKS_CLUSTER:-model-routing}"; AWS_REGION="${AWS_REGION:-eu-west-2}"
export EKS_CLUSTER AWS_REGION
banner() { echo; echo "==> $*"; }

banner "cluster $EKS_CLUSTER in $AWS_REGION"
if aws eks describe-cluster --region "$AWS_REGION" --name "$EKS_CLUSTER" >/dev/null 2>&1; then
  echo "    exists, skipping create"
  CREATED=0
else
  echo "    creating (about 20 minutes). --install-nvidia-plugin=false: the plugin is installed below."
  eksctl create cluster -f "$HERE/eks/cluster.yaml" --install-nvidia-plugin=false
  CREATED=1
fi
# Refresh the kubeconfig entry every time. A rebuilt cluster keeps its name but gets a new
# endpoint, and a stale ARN context then fails with "no such host" on the first kubectl.
aws eks update-kubeconfig --region "$AWS_REGION" --name "$EKS_CLUSTER" >/dev/null
. "$HERE/scripts/lib.sh"
if [ "$CREATED" = 1 ]; then
  kubectl -n kube-system create configmap lab-owner --from-literal=lab=agentgateway-inference-identity-routing-eks \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
fi

banner "EKS addons from eks/cluster.yaml (the EBS CSI driver is the one that matters)"
# Idempotent: existing addons are skipped. An eksctl create that gave up waiting on the GPU
# nodegroup leaves the addons uninstalled, and without the EBS CSI driver every PVC in the
# cluster sits Pending on "binding volumes: context deadline exceeded".
eksctl create addon -f "$HERE/eks/cluster.yaml" 2>&1 | grep -E "creating addon|active|already present" | sed 's/^.*\] */    /'

banner "GPU nodegroup at one node"
desired="$(aws eks describe-nodegroup --region "$AWS_REGION" --cluster-name "$EKS_CLUSTER" --nodegroup-name gpu \
  --query 'nodegroup.scalingConfig.desiredSize' --output text)"
if [ "$desired" != "1" ]; then "$HERE/scripts/gpu.sh" up; else echo "    desired=1"; fi

banner "default StorageClass (eksctl marks none)"
kubectl apply -f "$PART1_DIR/yaml/02-default-storageclass.yaml"

GWAPI_VERSION="${GWAPI_VERSION:-v1.6.1}"
AGW_VERSION="${AGW_VERSION:-v1.5.0}"
banner "Gateway API $GWAPI_VERSION, experimental channel"
kubectl apply --server-side --force-conflicts \
  -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GWAPI_VERSION}/experimental-install.yaml" >/dev/null
banner "agentgateway $AGW_VERSION"
helm_ upgrade --install agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
  --namespace "$NS" --create-namespace --version "$AGW_VERSION" --wait >/dev/null
helm_ upgrade --install agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --namespace "$NS" --version "$AGW_VERSION" \
  --set controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true --wait --timeout 5m >/dev/null
kubectl wait --for=jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'=True gatewayclass/agentgateway --timeout=180s

NVDP_VERSION="${NVDP_VERSION:-0.17.4}"
banner "NVIDIA device plugin $NVDP_VERSION"
# eksctl's own plugin, if a previous run installed it, hands out whole cards.
kubectl -n kube-system delete daemonset nvidia-device-plugin-daemonset --ignore-not-found >/dev/null
helm_ repo add nvdp https://nvidia.github.io/k8s-device-plugin >/dev/null 2>&1 || true
helm_ repo update nvdp >/dev/null
helm_ upgrade --install nvdp nvdp/nvidia-device-plugin \
  --namespace nvidia-device-plugin --create-namespace --version "$NVDP_VERSION" \
  -f "$HERE/yaml/01-device-plugin-values.yaml" --wait --timeout 5m >/dev/null
banner "waiting for both GPU nodes to advertise their card"
for _ in $(seq 1 40); do
  g="$(kubectl get nodes -l role=gpu -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null | grep -c '^1$' || true)"
  [ "${g:-0}" -ge 2 ] && break; sleep 10
done
kubectl get nodes -l role=gpu -o custom-columns='NODE:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu,MEM:.status.allocatable.memory'
[ "${g:-0}" -ge 2 ] || { echo "ERROR: fewer than two GPU nodes advertise a card. Check ./scripts/gpu.sh status" >&2; exit 1; }
echo
echo "Next: ./scripts/02-models.sh"
