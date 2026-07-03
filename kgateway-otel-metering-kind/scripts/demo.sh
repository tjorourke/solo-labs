#!/usr/bin/env bash
# Port-forward the gateway, send traffic, show per-customer usage from OpenMeter.
source "$(dirname "$0")/lib.sh"
k -n kgateway-system port-forward svc/http 8080:80 >/tmp/kgw-pf.log 2>&1 &
PF=$!; trap 'kill $PF 2>/dev/null' EXIT
sleep 4
step "Sending traffic"; "${ROOT}/scripts/gen.sh" "${1:-5}"
step "Waiting for async pipeline"; sleep 6
step "Per-customer usage from OpenMeter (api_requests_total)"
curl -s "${OM_URL}/api/v1/meters/api_requests_total/query?groupBy=subject" \
  | jq -r '.data[] | "  \(.subject): \(.value) calls"'
