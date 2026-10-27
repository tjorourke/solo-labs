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
# Ready pods can precede the first usable agent route after cold bootstrap.
# Poll the existing read-only check; every success still requires real records.
for attempt in {1..5}; do
  if python3 "$LAB/scripts/health.py"; then exit 0; fi
  if [[ "$attempt" -lt 5 ]]; then
    printf 'Read-only agent readiness attempt %s/5 failed; retrying in 3s.\n' "$attempt" >&2
    sleep 3
  fi
done
printf 'Native agent readiness did not return the expected customer record.\n' >&2
exit 1
