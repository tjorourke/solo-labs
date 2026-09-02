#!/usr/bin/env bash
# 00-kubeconfig.sh — kube contexts for both clusters, named after the clusters,
# straight from the tofu outputs.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require aws; require kubectl; require tofu
require_aws

step "kube contexts"
for c in "$CLUSTER_A" "$CLUSTER_B"; do
  aws eks update-kubeconfig --region "$AWS_REGION" --name "$c" --alias "$c" >/dev/null
  ok "context $c"
done

step "nodes"
for c in "$CLUSTER_A" "$CLUSTER_B"; do
  echo "[$c]"; kubectl --context "$c" get nodes -o wide --no-headers | awk '{print "   "$1, $2, $6}'
done
log "VM: $(tofu_out vm_private_ip) (private IP, instance $(tofu_out vm_instance_id))"
