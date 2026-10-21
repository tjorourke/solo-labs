#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
set +x
helm --kube-context "$CTX" upgrade -i vault vault --repo https://helm.releases.hashicorp.com -n vault --create-namespace --version 0.34.1 --set server.dev.enabled=true --set server.dev.devRootToken=root --set injector.enabled=false --wait --timeout=5m
k -n vault wait --for=create pod/vault-0 --timeout=180s
k -n vault wait --for=condition=Ready pod/vault-0 --timeout=180s
# A scoped, revocable Vault token is the mock bank's credential. Never echo it.
key=$(k -n vault exec vault-0 -- vault token create -policy=default -ttl=1h -format=json | python3 -c 'import json,sys;print(json.load(sys.stdin)["auth"]["client_token"])')
printf '%s' "$key" | k -n bank create secret generic core-bank-key --from-file=Authorization=/dev/stdin --dry-run=client -o yaml | apply_stdin
k -n bank create configmap core-bank --from-file="$LAB/scripts/core_bank.py" --dry-run=client -o yaml | apply_stdin
existing=false
if k -n bank get deployment core-bank >/dev/null 2>&1; then existing=true; fi
apply "$LAB/yaml/core-bank.yaml"
if [[ "$existing" == true ]]; then restart_deployment bank core-bank; fi
k -n bank rollout status deploy/core-bank --timeout=180s
k -n bank wait --for=condition=Programmed gateway/bank-gw --timeout=180s
k -n bank rollout status deploy/bank-gw --timeout=180s
sleep 5
result=$(incurl -w '\nHTTP %{http_code}\n' "$GW/core" -d '{}')
printf 'Before revocation: %s\n' "$result"
[[ "$result" == *'HTTP 200'* ]]
# Revocation is at the credential authority, without waiting for CSI refresh.
printf '%s' "$key" | k -n vault exec -i vault-0 -- sh -c 'read -r token || true; vault token revoke "$token" >/dev/null'
unset key
start=$SECONDS
result=$(incurl -w '\nHTTP %{http_code}\n' "$GW/core" -d '{}')
printf 'After revocation (%ss): %s\n' "$((SECONDS-start))" "$result"
[[ "$result" == *'HTTP 401'* ]]
bash "$LAB/scripts/renew-core-key.sh"
