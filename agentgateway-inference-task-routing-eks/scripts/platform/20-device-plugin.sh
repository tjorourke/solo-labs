#!/usr/bin/env bash
# Platform step 3: the NVIDIA device plugin, time-slicing the one card into two.
#
#   ./scripts/platform/20-device-plugin.sh
#
# The plugin hands out whole GPUs by default, so two vLLM pods each asking for one need two
# cards. From its Helm chart, with yaml/platform/20-device-plugin-values.yaml, it advertises
# the one card as nvidia.com/gpu: 2 and both pods schedule onto it. Time-slicing shares
# compute; the memory split is each vLLM's own --gpu-memory-utilization in the next step.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$HERE/scripts/lib.sh"
NVDP_VERSION="${NVDP_VERSION:-0.17.4}"

banner "NVIDIA device plugin $NVDP_VERSION"
# eksctl installs its own plugin on `create nodegroup` even when the cluster was created
# without one, and it hands out whole cards. Remove it so the two do not fight.
kubectl -n kube-system delete daemonset nvidia-device-plugin-daemonset --ignore-not-found >/dev/null
helm_ repo add nvdp https://nvidia.github.io/k8s-device-plugin >/dev/null 2>&1 || true
helm_ repo update nvdp >/dev/null
helm_ upgrade --install nvdp nvdp/nvidia-device-plugin \
  --namespace nvidia-device-plugin --create-namespace --version "$NVDP_VERSION" \
  -f "$HERE/yaml/platform/20-device-plugin-values.yaml" --wait --timeout 5m >/dev/null
echo "    installed"

banner "waiting for the node to advertise two GPU slices"
for _ in $(seq 1 40); do
  g="$(kubectl get nodes -l role=gpu -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null || true)"
  [ "$g" = "2" ] && break; sleep 10
done
kubectl get nodes -l role=gpu -o custom-columns='NODE:.metadata.name,GPU_SLICES:.status.allocatable.nvidia\.com/gpu,MEM:.status.allocatable.memory'
[ "$g" = "2" ] || { echo "ERROR: the GPU node does not advertise 2 slices" >&2; exit 1; }
echo
echo "Next: ./scripts/platform/30-models.sh"
