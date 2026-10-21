#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
set +x
key=$(k -n vault exec vault-0 -- vault token create -policy=default -ttl=1h -format=json | python3 -c 'import json,sys;print(json.load(sys.stdin)["auth"]["client_token"])')
printf '%s' "$key" | k -n bank create secret generic core-bank-key --from-file=Authorization=/dev/stdin --dry-run=client -o yaml | apply_stdin
unset key
# Allow the existing gateway to receive the Secret update, without a restart.
for attempt in {1..30}; do
  result=$(incurl -w '\nHTTP %{http_code}\n' "$GW/core" -d '{}')
  [[ "$result" == *'HTTP 200'* ]] && exit 0
  sleep 1
done
printf 'Gateway did not receive the replacement credential\n' >&2
exit 1
