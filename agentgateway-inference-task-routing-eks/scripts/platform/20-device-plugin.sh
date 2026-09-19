#!/usr/bin/env bash
# Platform step 2: the NVIDIA device plugin.
#
#   ./scripts/platform/20-device-plugin.sh
#
# The plugin hands out whole GPUs, which is what this lab wants: two GPU nodes, one model on
# each, and every card's 96 GB available to the model that holds it. From its Helm chart,
# with yaml/platform/20-device-plugin-values.yaml.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$HERE/scripts/lib.sh"
NVDP_VERSION="${NVDP_VERSION:-0.17.4}"

banner "NVIDIA device plugin $NVDP_VERSION"
# A plugin the cluster tooling installed on its own (several managed-cluster tools do) hands out whole
# cards. Remove it so the two do not fight.
kubectl -n kube-system delete daemonset nvidia-device-plugin-daemonset --ignore-not-found >/dev/null
helm_ repo add nvdp https://nvidia.github.io/k8s-device-plugin >/dev/null 2>&1 || true
helm_ repo update nvdp >/dev/null
helm_ upgrade --install nvdp nvdp/nvidia-device-plugin \
  --namespace nvidia-device-plugin --create-namespace --version "$NVDP_VERSION" \
  -f "$HERE/yaml/platform/20-device-plugin-values.yaml" --wait --timeout 5m >/dev/null
echo "    installed"

banner "waiting for both GPU nodes to advertise their card"
for _ in $(seq 1 40); do
  n="$(kubectl get nodes -l role=gpu -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null | grep -c '^1$' || true)"
  [ "${n:-0}" -ge 2 ] && break; sleep 10
done
kubectl get nodes -l role=gpu -o custom-columns='NODE:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu,MEM:.status.allocatable.memory'
[ "${n:-0}" -ge 2 ] || { echo "ERROR: fewer than two GPU nodes advertise a card. Check ./scripts/gpu.sh status" >&2; exit 1; }
echo
echo "Next: ./scripts/platform/30-models.sh"
