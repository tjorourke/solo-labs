#!/usr/bin/env bash
# Start and stop the GPU meter. The only expensive thing in this lab.
#
#   ./scripts/gpu.sh up      one g7e.2xlarge, about $5.85/hr
#   ./scripts/gpu.sh down    scale to zero; the weights stay on their volumes
#   ./scripts/gpu.sh status
#
# One node, not Part 1's two: both open-weight models share the card through the device
# plugin's time-slicing (scripts/01-cluster.sh). down is safe at the end of a session; the
# weights sit on gp3 volumes pinned to the same AZ, so up brings the models back in
# minutes rather than re-pulling 76 GB.
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
  up)     scale 1; echo "waiting for the node to advertise its GPU (up to 30m)"; wait_gpu 1 ;;
  down)   scale 0; echo "GPU meter stopped. Weights stay on their volumes." ;;
  status)
    aws eks describe-nodegroup --region "$AWS_REGION" --cluster-name "$EKS_CLUSTER" --nodegroup-name "$NG" \
      --query 'nodegroup.{desired:scalingConfig.desiredSize,type:instanceTypes,status:status,health:health.issues}' --output json
    kubectl get nodes -l role=gpu -o custom-columns='NODE:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu' 2>/dev/null || true
    ;;
  *) echo "usage: $0 {up|down|status}" >&2; exit 1 ;;
esac
