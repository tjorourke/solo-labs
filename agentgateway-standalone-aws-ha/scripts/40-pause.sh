#!/bin/bash
# Park the stack without destroying it, for when you want it back tomorrow.
#
# Scales the autoscaling group to zero and stops the Aurora cluster. Nothing is deleted:
# the launch template, load balancer, target group, ElastiCache, Cognito pool, S3 bucket
# and the runtime secret all stay, and Aurora keeps its data, including the configuration
# overlay that the fleet reads at boot.
#
# Bring it back with scripts/41-resume.sh.
#
# Two things to know:
#
#   A stopped Aurora cluster starts itself again after seven days. That is enforced by
#   AWS, not by this script, so a stack parked for longer than a week will quietly begin
#   billing capacity again. For a longer break use scripts/teardown.sh and re-apply when
#   you next need it, which takes about twenty minutes.
#
#   The capacity of the group is managed by Terraform, so `tofu apply` puts the nodes
#   back. While the stack is parked, resume with 41-resume.sh rather than re-applying.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_tools; require_aws; require_stack

ASG="$(tf_out autoscaling_group_name)"
WRITER="$(tf_out aurora_writer_endpoint)"
CLUSTER="$(aws rds describe-db-clusters \
  --query "DBClusters[?Endpoint=='${WRITER}'].DBClusterIdentifier" --output text)"
[[ -n "$CLUSTER" ]] || die "could not resolve the Aurora cluster from $WRITER"

hdr "Scaling the group to zero"
log "group: $ASG"
aws autoscaling update-auto-scaling-group --auto-scaling-group-name "$ASG" \
  --min-size 0 --desired-capacity 0
ok "min and desired set to 0"

hdr "Stopping the Aurora cluster"
log "cluster: $CLUSTER (the data is kept)"
aws rds stop-db-cluster --db-cluster-identifier "$CLUSTER" \
  --query 'DBCluster.Status' --output text | sed 's/^/    /'

hdr "Waiting for the nodes to terminate"
for i in $(seq 1 60); do
  n="$(aws ec2 describe-instances \
        --filters "Name=tag:aws:autoscaling:groupName,Values=$ASG" \
                  "Name=instance-state-name,Values=running,pending,shutting-down" \
        --query 'length(Reservations[].Instances[])' --output text)"
  printf '    t+%-4ss instances=%s\n' $((i*10)) "$n"
  [[ "$n" == "0" ]] && break
  sleep 10
done
expect "no gateway instances left running" 0 "$(aws ec2 describe-instances \
  --filters "Name=tag:aws:autoscaling:groupName,Values=$ASG" \
            "Name=instance-state-name,Values=running,pending" \
  --query 'length(Reservations[].Instances[])' --output text)"

hdr "Waiting for Aurora to finish stopping"
for i in $(seq 1 60); do
  s="$(aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER" \
        --query 'DBClusters[0].Status' --output text)"
  printf '    t+%-4ss %s\n' $((i*10)) "$s"
  [[ "$s" == "stopped" ]] && break
  sleep 10
done
expect "Aurora is stopped" stopped "$(aws rds describe-db-clusters \
  --db-cluster-identifier "$CLUSTER" --query 'DBClusters[0].Status' --output text)"

hdr "What is still billed"
cat <<'EOT'
  Compute is off. What remains cannot be paused, only deleted:

    NAT gateways, one per zone   the largest remaining item once the nodes are off
    the load balancer
    the ElastiCache replication group
    Aurora storage, S3, the secret, the Cognito pool   negligible

  If the stack is going to sit idle for more than a week, teardown.sh is cheaper than
  parking it.
EOT

summary
