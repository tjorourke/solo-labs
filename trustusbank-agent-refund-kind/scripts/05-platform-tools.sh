#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
set +x
source "${SECRETS_FILE:-$HOME/code/solo/secrets/secrets-envs.sh}" >/dev/null 2>&1
: "${ANTHROPIC_API_KEY:?Anthropic key required}"
printf '%s' "$ANTHROPIC_API_KEY" | k -n bank create secret generic anthropic-key --from-file=Authorization=/dev/stdin --dry-run=client -o yaml | apply_stdin
printf '%s' placeholder | k -n bank create secret generic bank-model-placeholder --from-file=ANTHROPIC_API_KEY=/dev/stdin --dry-run=client -o yaml | apply_stdin
if ! k -n bank get secret fraud-vendor-key >/dev/null 2>&1; then
  python3 -c 'import secrets;print(secrets.token_urlsafe(32),end="")' | k -n bank create secret generic fraud-vendor-key --from-file=X-Api-Key=/dev/stdin --dry-run=client -o yaml | apply_stdin
fi
k -n bank create configmap core-bank --from-file="$LAB/scripts/core_bank.py" --dry-run=client -o yaml | apply_stdin
# Migrate the old HTTP gateway once; its generated Service must be removed
# before creating the stable, selectorless waypoint Service with the same name.
if k -n bank get gateway bank-gw >/dev/null 2>&1; then
  k -n bank delete gateway bank-gw
  k -n bank wait --for=delete service/bank-gw --timeout=60s
fi
apply "$LAB/yaml/core-bank.yaml"
for name in payments customers fraud; do
  k -n bank create configmap "$name-mcp" --from-file="$LAB/scripts/${name}_mcp.py" --from-file="$LAB/scripts/bank_data.py" --dry-run=client -o yaml | apply_stdin
done
k -n bank create configmap fraud-vendor --from-file="$LAB/scripts/fraud_vendor.py" --dry-run=client -o yaml | apply_stdin
apply "$LAB/yaml/tools.yaml"
apply "$LAB/yaml/payments.yaml"
apply "$LAB/yaml/egress.yaml"
apply "$LAB/yaml/receipt-identity.yaml"
apply "$LAB/yaml/audit.yaml"
for name in payments-mcp customers-mcp fraud-mcp fraud-vendor; do
  restart_deployment bank "$name"
  k -n bank rollout status "deployment/$name" --timeout=300s
done
