#!/usr/bin/env bash
# Check this standalone lab. No refund writes or receipt resets.
source "$(dirname "$0")/lib.sh"
k get --raw=/readyz >/dev/null
for item in agentgateway-system/enterprise-agentgateway kagent/kagent-controller keycloak/keycloak bank/bank-waypoint bank/customer-service-assistant bank/customer-agent bank/fraud-agent bank/refunds-agent bank/payments-assistant bank/payments-manager; do
  k -n "${item%/*}" rollout status "deployment/${item#*/}" --timeout=180s
done
result=$(core_probe)
if [[ "$result" == *'HTTP 401'* ]]; then
  printf 'Renewing the expired bank credential without restarting workloads.\n'
  bash "$LAB/scripts/renew-core-key.sh"
elif [[ "$result" != *'HTTP 200'* ]]; then
  printf 'Bank egress is unavailable: %s\n' "$result" >&2
  exit 1
fi
python3 "$LAB/scripts/health.py"
