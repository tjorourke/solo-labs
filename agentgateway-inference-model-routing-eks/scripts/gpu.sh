#!/usr/bin/env bash
# Start and stop the GPU meter. The only expensive thing in this lab.
#
#   ./scripts/gpu.sh up      two g7e.2xlarge, about $11.70/hr together
#   ./scripts/gpu.sh down    scale to zero; the weights stay on their volumes
#   ./scripts/gpu.sh status
#
# down is safe to run at the end of a session: the weights are on gp3 volumes pinned to
# one AZ, so up brings the same nodes back to the same volumes and vLLM reloads in
# minutes rather than re-pulling 76 GB.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER="${EKS_CLUSTER:-model-routing}"
REGION="${AWS_REGION:-eu-west-2}"
NG="${GPU_NODEGROUP:-gpu}"
export EKS_CLUSTER="$CLUSTER" AWS_REGION="$REGION"
. "$HERE/scripts/lib-context.sh"

scale() {
  aws eks update-nodegroup-config --region "$REGION" --cluster-name "$CLUSTER" \
    --nodegroup-name "$NG" --scaling-config "minSize=0,maxSize=2,desiredSize=$1" >/dev/null
  echo "$NG -> desired=$1"
}

case "${1:-status}" in
  up)
    scale 2
    echo "waiting for both nodes to advertise a GPU (up to 30m)"
    resolve_ctx
    for _ in $(seq 1 120); do
      n=$(kubectl --context "$CTX" get nodes -l role=gpu \
            -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null \
          | grep -c '^1$' || true)
      [ "${n:-0}" -ge 2 ] && { echo "$n GPU nodes ready"; exit 0; }
      sleep 15
    done
    # Nodegroup HEALTH, not the node list: an ASG that cannot launch reports DEGRADED
    # while kubectl shows nothing at all and reads as ordinary slowness.
    echo "ERROR: fewer than 2 GPU nodes within 30m. Check nodegroup health:" >&2
    aws eks describe-nodegroup --region "$REGION" --cluster-name "$CLUSTER" \
      --nodegroup-name "$NG" --query 'nodegroup.health' --output json >&2
    exit 1
    ;;
  down)   scale 0; echo "GPU meter stopped. Weights stay on their volumes." ;;
  status)
    aws eks describe-nodegroup --region "$REGION" --cluster-name "$CLUSTER" \
      --nodegroup-name "$NG" \
      --query 'nodegroup.{desired:scalingConfig.desiredSize,type:instanceTypes,status:status,health:health.issues}' \
      --output json
    ;;
  *) echo "usage: $0 {up|down|status}" >&2; exit 1 ;;
esac
