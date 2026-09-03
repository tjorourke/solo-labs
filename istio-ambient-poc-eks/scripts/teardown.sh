#!/usr/bin/env bash
# teardown.sh — delete the LoadBalancer Services first (each one is an AWS NLB
# that the VPC cannot be destroyed underneath), then tofu destroy everything.
#
# The wait is a POLL, not a fixed sleep. The in-tree cloud provider holds the
# service.kubernetes.io/load-balancer-cleanup finalizer on each Service until it
# has actually deleted the NLB, so "no LoadBalancer Services left" is the real
# signal that the NLBs are gone. A fixed `sleep 60` only ever worked because
# tofu then spends ~10 minutes on the node groups before it reaches the VPCs.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_aws

LB_WAIT_SECS="${LB_WAIT_SECS:-600}"
RESIDUE=0

lb_services() { # <context> — "<ns> <name>" per LoadBalancer Service
  kubectl --context "$1" get svc -A -o json 2>/dev/null \
    | python3 -c "import json,sys; [print(i['metadata']['namespace'], i['metadata']['name']) for i in json.load(sys.stdin)['items'] if i['spec'].get('type')=='LoadBalancer']"
}

for c in "$CLUSTER_A" "$CLUSTER_B"; do
  kubectl config get-contexts -o name | grep -qx "$c" || continue
  step "[$c] removing LoadBalancer services"
  kubectl --context "$c" delete gateway --all -n "$EW_NS" --ignore-not-found --timeout=120s >/dev/null 2>&1 || true
  helm --kube-context "$c" uninstall istio-eastwest -n "$EW_NS" >/dev/null 2>&1 || true
  lb_services "$c" | while read -r ns name; do
    [[ -n "$ns" ]] || continue
    kubectl --context "$c" -n "$ns" delete svc "$name" --wait=false >/dev/null 2>&1 || true
    log "requested deletion of svc $ns/$name"
  done
done

step "waiting for the NLBs to actually go (up to ${LB_WAIT_SECS}s)"
deadline=$(( $(date +%s) + LB_WAIT_SECS ))
while :; do
  remaining=""
  for c in "$CLUSTER_A" "$CLUSTER_B"; do
    kubectl config get-contexts -o name | grep -qx "$c" || continue
    while read -r ns name; do
      [[ -n "$ns" ]] && remaining+="$c:$ns/$name "
    done < <(lb_services "$c")
  done
  [[ -z "$remaining" ]] && { ok "all LoadBalancer Services gone, so the NLBs are deleted"; break; }
  if [[ $(date +%s) -ge $deadline ]]; then
    warn "still present after ${LB_WAIT_SECS}s: $remaining"
    warn "tofu destroy will fail on the VPCs while an NLB survives. Check the"
    warn "Service finalizers and any orphaned NLB in the console, then re-run."
    RESIDUE=1
    break
  fi
  log "still deleting: $remaining"
  sleep 15
done

step "tofu destroy"
if tofu -chdir="$TOFU_DIR" destroy -auto-approve; then
  ok "tofu destroy complete"
else
  warn "tofu destroy failed — re-run this script; VPC dependencies are the usual cause"
  RESIDUE=1
fi

for c in "$CLUSTER_A" "$CLUSTER_B"; do kubectl config delete-context "$c" >/dev/null 2>&1 || true; done

# Verify rather than assume. This lab bills for two EKS control planes, four
# nodes, a VM and the NLBs, so "tofu said ok" is not good enough to walk away on.
step "verifying $AWS_REGION is clear"
# A failed query must NOT read as "none". `aws ... || echo 0` was doing exactly
# that: point it at a bad region and every check reported clear.
check() { # <label> <command...>
  local label="$1"; shift
  local out rc=0
  # `out="$(cmd)"; rc=$?` never reaches rc=$? under `set -e`: the failing
  # assignment aborts the script first. Keep the || so this stays a condition.
  out="$("$@" 2>/dev/null)" || rc=$?
  if [[ $rc -ne 0 || -z "$out" ]]; then
    warn "$label: COULD NOT VERIFY (query failed)"; RESIDUE=1; return
  fi
  if [[ "$out" == 0 ]]; then ok "$label: none"; else warn "$label: $out STILL PRESENT"; RESIDUE=1; fi
}
check "EKS clusters"     aws eks list-clusters --query 'length(clusters)' --output text
check "EC2 instances"    aws ec2 describe-instances --filters 'Name=instance-state-name,Values=running,pending,stopping,stopped' --query 'length(Reservations[].Instances[])' --output text
check "non-default VPCs" aws ec2 describe-vpcs --filters 'Name=isDefault,Values=false' --query 'length(Vpcs)' --output text
check "VPC peerings"     aws ec2 describe-vpc-peering-connections --filters 'Name=status-code,Values=active,pending-acceptance,provisioning' --query 'length(VpcPeeringConnections)' --output text
check "load balancers"   aws elbv2 describe-load-balancers --query 'length(LoadBalancers)' --output text
check "NAT gateways"     aws ec2 describe-nat-gateways --filter 'Name=state,Values=available,pending' --query 'length(NatGateways)' --output text
n_state="$(python3 -c "import json,sys;print(sum(1 for r in json.load(open(sys.argv[1]))['resources'] if r['mode']=='managed'))" "$TOFU_DIR/terraform.tfstate" 2>/dev/null || echo 0)"
if [[ "$n_state" == 0 ]]; then ok "resources in tofu state: none"; else warn "resources in tofu state: $n_state STILL PRESENT"; RESIDUE=1; fi

# Detached EBS volumes still bill, and DeleteOnTermination misses PVC-backed
# ones, so report any (without deleting: this region may hold other people's).
vols="$(aws ec2 describe-volumes --filters 'Name=status,Values=available' --query 'Volumes[].[VolumeId,Size]' --output text 2>/dev/null || true)"
if [[ -n "$vols" ]]; then
  warn "detached EBS volumes in $AWS_REGION (these bill; confirm whose before deleting):"
  echo "$vols" | sed 's/^/      /' >&2
fi

if [[ "$RESIDUE" == 0 ]]; then step "gone — $AWS_REGION is clear"; else step "TEARDOWN INCOMPLETE — see the warnings above"; exit 1; fi
