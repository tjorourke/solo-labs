#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
chain
result=$(incurl --max-time 180 -w '\nHTTP %{http_code}\n' http://orchestrator.bank.svc:8080/ -H "authorization: Bearer $H1" -H 'content-type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"message/send","params":{"message":{"role":"user","messageId":"refund-request","parts":[{"kind":"text","text":"Investigate PAY-7781 and refund if valid"}]}}}')
printf '%s\n' "$result"
[[ "$result" == *'ISSUED'* && "$result" == *'HTTP 200'* ]]
result=$(incurl -w '\nHTTP %{http_code}\n' http://orchestrator.bank.svc:8080/ -H 'content-type: application/json' -d '{}')
printf 'Anonymous A2A: %s\n' "$result"; [[ "$result" == *'HTTP 401'* ]]
