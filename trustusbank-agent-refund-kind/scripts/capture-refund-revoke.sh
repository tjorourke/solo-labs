#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
source "$LAB/scripts/mcp.sh"
set +x
bash "$LAB/scripts/renew-core-key.sh"
trap 'bash "$LAB/scripts/renew-core-key.sh"' EXIT
chain
result=$(mcp_call "$H2" refund_payment '{"payment_id":"PAY-7781","amount_gbp":1250}')
printf 'Refund before Vault revocation: %s\n' "$result"
[[ "$result" == *'ISSUED'* && "$result" != *'"isError":true'* ]]
k -n bank get secret core-bank-key -o jsonpath='{.data.Authorization}' | python3 -c 'import base64,sys;sys.stdout.buffer.write(base64.b64decode(sys.stdin.read()))' | k -n vault exec -i vault-0 -- sh -c 'read -r token || true; vault token revoke "$token" >/dev/null'
result=$(mcp_call "$H2" refund_payment '{"payment_id":"PAY-7781","amount_gbp":1250}')
printf 'Refund after Vault revocation: %s\n' "$result"
[[ "$result" == *'Core bank refused refund: HTTP 401'* && "$result" == *'"isError":true'* ]]
