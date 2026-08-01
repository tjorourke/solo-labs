#!/bin/bash
# Bring a parked stack back to a full fleet.
#
# There is nothing to restore by hand. Each node boots, renders its environment from the
# runtime secret, reads the configuration file from S3, picks up the overlay from Aurora
# and joins the target group. Aurora has to be available first, because a node reads the
# overlay while it starts.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_tools; require_aws; require_stack

ASG="$(tf_out autoscaling_group_name)"
WRITER="$(tf_out aurora_writer_endpoint)"
CLUSTER="$(aws rds describe-db-clusters \
  --query "DBClusters[?Endpoint=='${WRITER}'].DBClusterIdentifier" --output text)"
[[ -n "$CLUSTER" ]] || die "could not resolve the Aurora cluster from $WRITER"
SIZE="${FLEET_SIZE:-3}"

hdr "Starting the Aurora cluster"
status="$(aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER" \
  --query 'DBClusters[0].Status' --output text)"
if [[ "$status" == "stopped" ]]; then
  aws rds start-db-cluster --db-cluster-identifier "$CLUSTER" \
    --query 'DBCluster.Status' --output text | sed 's/^/    /'
else
  log "cluster is already $status"
fi
log "waiting until it is available, because the nodes read the overlay at boot"
aws rds wait db-cluster-available --db-cluster-identifier "$CLUSTER"
ok "Aurora available"

hdr "Restoring the group to $SIZE nodes"
aws autoscaling update-auto-scaling-group --auto-scaling-group-name "$ASG" \
  --min-size "$SIZE" --desired-capacity "$SIZE"
ok "min and desired set to $SIZE"

hdr "Waiting for the load balancer to report a full fleet"
for i in $(seq 1 90); do
  h="$(healthy_count)"
  printf '    t+%-4ss healthy=%s\n' $((i*10)) "$h"
  [[ "$h" == "$SIZE" ]] && break
  sleep 10
done
expect "$SIZE healthy targets" "$SIZE" "$(healthy_count)"

hdr "Confirming the fleet is answering, and that requests spread"
for _ in $(seq 1 9); do whoami_node; done | sort | uniq -c | sed 's/^/    /'

log "Run scripts/02-verify.sh for the full check."
summary
