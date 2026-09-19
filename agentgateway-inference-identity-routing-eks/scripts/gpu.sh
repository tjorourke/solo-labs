#!/usr/bin/env bash
# Start and stop the GPU meter. The only expensive thing in this lab.
#
#   ./scripts/gpu.sh up      two g7e.2xlarge, about $11.70/hr
#   ./scripts/gpu.sh down    scale to zero; the weights stay on their volumes
#   ./scripts/gpu.sh status
#
# Two nodes, a card each. One card between the two models works, and costs both of them
# their context window: the 96 GB is split by --gpu-memory-utilization, the KV cache shrinks
# with it, and vLLM refuses any request longer than the window it can serve. An agent client
# feels that first, because it sends its instructions and its tools on every turn. A card
# each gives Mistral a 131072 window and Qwen 262144.
#
# down is safe at the end of a session; the weights sit on gp3 volumes pinned to the same AZ,
# so up brings the models back in minutes rather than re-pulling 76 GB.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/scripts/lib.sh"
NG="${GPU_NODEGROUP:-gpu}"
scale() {
  aws eks update-nodegroup-config --region "$AWS_REGION" --cluster-name "$EKS_CLUSTER" \
    --nodegroup-name "$NG" --scaling-config "minSize=0,maxSize=2,desiredSize=$1" >/dev/null
  echo "$NG -> desired=$1"
}
wait_gpu() { # wait_gpu <count>  -> until that many nodes advertise a GPU
  for _ in $(seq 1 120); do
    n=$(kubectl get nodes -l role=gpu -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null | grep -c -v '^$' || true)
    if [ "${n:-0}" -ge "$1" ]; then echo "$n GPU node(s) advertising a GPU"; return 0; fi
    sleep 15
  done
  echo "ERROR: no GPU node advertised a GPU within 30m." >&2
  # The reason lives on the Auto Scaling group, not the nodegroup: a capacity refusal
  # reads "InsufficientInstanceCapacity ... in the Availability Zone you requested" and
  # names an AZ that has stock. Move the nodegroup there (eks/cluster.yaml) if no volume
  # pins it yet.
  for asg in $(aws autoscaling describe-auto-scaling-groups --region "$AWS_REGION" \
      --query "AutoScalingGroups[?Tags[?Key=='eks:nodegroup-name' && Value=='$NG'] && Tags[?Key=='eks:cluster-name' && Value=='$EKS_CLUSTER']].AutoScalingGroupName" --output text); do
    aws autoscaling describe-scaling-activities --region "$AWS_REGION" --auto-scaling-group-name "$asg" \
      --max-items 2 --query 'Activities[].[StatusCode,StatusMessage]' --output text >&2
  done
  return 1
}
case "${1:-status}" in
  up)     scale 2; echo "waiting for both nodes to advertise a GPU (up to 30m)"; wait_gpu 2 ;;
  down)   scale 0; echo "GPU meter stopped. Weights stay on their volumes." ;;
  status)
    aws eks describe-nodegroup --region "$AWS_REGION" --cluster-name "$EKS_CLUSTER" --nodegroup-name "$NG" \
      --query 'nodegroup.{desired:scalingConfig.desiredSize,type:instanceTypes,status:status,health:health.issues}' --output json
    kubectl get nodes -l role=gpu -o custom-columns='NODE:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu' 2>/dev/null || true
    ;;
  *) echo "usage: $0 {up|down|status}" >&2; exit 1 ;;
esac
