#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
case "${1:-}" in
  on)
    apply "$LAB/yaml/killswitch.yaml"
    for attempt in {1..60}; do
      if k -n bank get accesspolicy refunds-agent-killswitch -o json | python3 -c 'import json,sys;d=json.load(sys.stdin);sys.exit(d.get("status",{}).get("state") != "Applied")'; then break; fi
      sleep 1
    done
    k -n bank get enterpriseagentgatewaypolicy accesspolicy-refunds-agent-killswitch-waypoint -o name
    ;;
  off)
    k -n bank delete accesspolicy refunds-agent-killswitch --ignore-not-found
    k -n bank wait --for=delete enterpriseagentgatewaypolicy/accesspolicy-refunds-agent-killswitch-waypoint --timeout=60s
    ;;
  *) echo 'Usage: bash scripts/killswitch.sh on|off' >&2; exit 2 ;;
esac
printf 'kagent policies: http://refund-lab.localhost:19380/ke/access-policies/\n'
printf 'Agent: http://refund-lab.localhost:19380/ke/agents/trustusbank-lab/bank/payments-assistant/\n'
printf 'Gateway policies: http://refund-lab.localhost:19380/age/policies\n'
