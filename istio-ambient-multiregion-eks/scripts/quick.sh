#!/usr/bin/env bash
# quick.sh — the labs-e2e entry point for this lab: build, run, tear down.
#
#   ./scripts/quick.sh up         create both EKS clusters, then every stage
#   ./scripts/quick.sh teardown   delete both clusters
#   ./scripts/quick.sh status     what exists right now
#
# This lab builds REAL AWS infrastructure in TWO regions (eu-central-1 and
# eu-west-1), three m5.large nodes each plus NLBs, and it costs money for as long
# as it is up. Teardown is mandatory and the harness always calls it.
#
# Cluster creation was previously a manual eksctl step from the README, which is
# why the harness could never run this lab. The eksctl configs were already in
# the repo; this just calls them.
#
# Needs LAB_AWS_PROFILE (or AWS_PROFILE) and SOLO_ISTIO_LICENSE_KEY.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

export LAB_AWS_PROFILE="${LAB_AWS_PROFILE:-${AWS_PROFILE:-}}"
export AWS_PROFILE="${AWS_PROFILE:-${LAB_AWS_PROFILE:-}}"

[[ -f "${SECRETS_FILE:-}" ]] && { set -a; . "$SECRETS_FILE"; set +a; }

# Same defaults the stage scripts use, so `status` and `teardown` agree with them.
REGION1="${REGION1:-eu-central-1}"; NAME1="${NAME1:-mesh-eu-central}"
REGION2="${REGION2:-eu-west-1}";    NAME2="${NAME2:-mesh-eu-west}"

have_cluster() { eksctl get cluster --name "$1" --region "$2" >/dev/null 2>&1; }

case "${1:-up}" in
  up)
    [[ -n "$AWS_PROFILE" ]] || { echo "quick.sh: set LAB_AWS_PROFILE or AWS_PROFILE" >&2; exit 2; }
    command -v eksctl >/dev/null || { echo "quick.sh: eksctl not found" >&2; exit 2; }

    # Build both regions at once. Each takes 15-20 minutes and they are
    # independent, so serialising them would double the bill for no reason.
    pids=()
    for pair in "$NAME1:$REGION1:mesh-eu-central" "$NAME2:$REGION2:mesh-eu-west"; do
      IFS=: read -r name region cfg <<<"$pair"
      if have_cluster "$name" "$region"; then
        echo "==> $name already exists in $region"
      else
        echo "==> Creating $name in $region"
        eksctl create cluster -f "$LAB_ROOT/eksctl/${cfg}.yaml" &
        pids+=($!)
      fi
    done
    rc=0; for p in "${pids[@]:-}"; do [[ -n "$p" ]] && { wait "$p" || rc=1; }; done
    [[ $rc -eq 0 ]] || { echo "quick.sh: a cluster failed to create" >&2; exit 1; }

    # 07 and 09 take an argument; the rest do not. 07 wants the Global Accelerator
    # DNS name, which 05 created and AWS can tell us. 09 wants a Route53 failover
    # record, which only exists when HOSTED_ZONE_ID and RECORD_NAME are set AND the
    # zone is publicly delegated, so it is skipped rather than failed when it
    # cannot apply.
    for s in 01-istio 02-peering 03-app 04-demo-pod-failover 05-ingress-ga 06-scale; do
      echo; echo "################  $s  ################"
      bash "$SCRIPT_DIR/$s.sh" || { echo "FAILED at $s" >&2; exit 1; }
    done

    echo; echo "################  07-demo-region-failover  ################"
    GA_DNS="$(aws globalaccelerator list-accelerators --region us-west-2 \
              --query "Accelerators[?Name=='mesh-multiregion'].DnsName|[0]" --output text 2>/dev/null)"
    if [[ -n "$GA_DNS" && "$GA_DNS" != "None" ]]; then
      bash "$SCRIPT_DIR/07-demo-region-failover.sh" "$GA_DNS" \
        || { echo "FAILED at 07-demo-region-failover" >&2; exit 1; }
    else
      echo "  skipped: no Global Accelerator named mesh-multiregion found"
    fi

    for s in 08-dns-route53 09-demo-dns-failover; do
      if [[ -z "${HOSTED_ZONE_ID:-}" || -z "${RECORD_NAME:-}" ]]; then
        echo; echo "################  $s (skipped)  ################"
        echo "  needs HOSTED_ZONE_ID and RECORD_NAME, and a publicly delegated zone"
        continue
      fi
      echo; echo "################  $s  ################"
      if [[ "$s" == 09-demo-dns-failover ]]; then
        bash "$SCRIPT_DIR/$s.sh" "$RECORD_NAME" || { echo "FAILED at $s" >&2; exit 1; }
      else
        bash "$SCRIPT_DIR/$s.sh" || { echo "FAILED at $s" >&2; exit 1; }
      fi
    done
    ;;
  teardown)
    bash "$SCRIPT_DIR/teardown.sh" || {
      # Two EKS clusters left running is the expensive failure, so fall back to
      # deleting them directly rather than leaving them to a later tidy-up.
      echo "quick.sh: teardown.sh failed, deleting the clusters directly" >&2
      eksctl delete cluster --name "$NAME1" --region "$REGION1" --wait || true
      eksctl delete cluster --name "$NAME2" --region "$REGION2" --wait || true
    }
    ;;
  status)
    for pair in "$NAME1:$REGION1" "$NAME2:$REGION2"; do
      IFS=: read -r name region <<<"$pair"
      have_cluster "$name" "$region" && echo "  $name ($region): present" || echo "  $name ($region): gone"
    done
    ;;
  *)
    echo "usage: quick.sh up|teardown|status" >&2; exit 2
    ;;
esac
