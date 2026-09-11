#!/usr/bin/env bash
# Start and stop the GPU meter. The only expensive thing in this lab.
#
#   ./scripts/gpu.sh up       two g7e.2xlarge, about $11.70/hr together
#   ./scripts/gpu.sh down     scale to zero; the weights stay on their volumes
#   ./scripts/gpu.sh status
#
# down is safe at the end of a session: each replica's weights are on its own gp3 volume
# pinned to one AZ, so up brings the nodes back to the same volumes and vLLM reloads in
# minutes rather than re-pulling 62 GB.
#
# TWO, NOT ONE. Scaling to a single card leaves the lab running and pointless: the
# Endpoint Picker scores a pool of one replica and returns it every time, which looks
# exactly like a working scheduler and proves nothing. 02-models.sh refuses to deploy
# against fewer than two for the same reason.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require aws

scale() {
  aws eks update-nodegroup-config --region "$AWS_REGION" --cluster-name "$EKS_CLUSTER" \
    --nodegroup-name "$GPU_NODEGROUP" --scaling-config "minSize=0,maxSize=2,desiredSize=$1" >/dev/null
  ok "$GPU_NODEGROUP -> desired=$1"
}

case "${1:-status}" in
  up)
    scale 2
    log "waiting for both nodes to advertise a GPU (up to 30m)"
    resolve_ctx
    for _ in $(seq 1 120); do
      n=$(kc get nodes -l role=gpu \
            -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null \
          | grep -c '^1$' || true)
      if [ "${n:-0}" -ge 2 ]; then
        ok "$n GPU nodes ready"
        # Coming back from zero, the StatefulSet pods are Pending, not gone. Nudge them
        # so the reload starts now rather than at the next scheduler sweep, and report
        # honestly if the weights are not where they were left.
        kc -n "$NS" rollout status statefulset/vllm --timeout=1200s 2>/dev/null \
          || warn "replicas not Ready yet — watch: kc -n $NS get pods -l app=vllm -w"
        exit 0
      fi
      sleep 15
    done
    # Nodegroup HEALTH, not the node list: an ASG that cannot launch reports DEGRADED
    # while kubectl shows nothing at all and reads as ordinary slowness.
    warn "fewer than 2 GPU nodes within 30m. Nodegroup health:"
    aws eks describe-nodegroup --region "$AWS_REGION" --cluster-name "$EKS_CLUSTER" \
      --nodegroup-name "$GPU_NODEGROUP" --query 'nodegroup.health' --output json >&2
    die "capacity, not configuration, is the usual cause in eu-west-2. Hold the pair with an On-Demand Capacity Reservation before a rehearsal."
    ;;
  down)
    scale 0
    ok "GPU meter stopped. Weights stay on their volumes."
    ;;
  status)
    aws eks describe-nodegroup --region "$AWS_REGION" --cluster-name "$EKS_CLUSTER" \
      --nodegroup-name "$GPU_NODEGROUP" \
      --query 'nodegroup.{desired:scalingConfig.desiredSize,type:instanceTypes,status:status,health:health.issues}' \
      --output json
    ;;
  *) die "usage: $0 {up|down|status}" ;;
esac
