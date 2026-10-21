#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
tools
chain
printf '%s' "$H1" | claims | python3 -c 'import json,sys;d=json.load(sys.stdin);print("Signed in:",d["preferred_username"]);print("Assistant:",d["act"]["sub"].split(":")[-1]);print("Request is acting for:",d["preferred_username"])'
result=$(incurl -w '\nHTTP %{http_code}\n' "$KC" -d grant_type=password -d client_id=payments-ops)
printf '%s\n' "$result"
[[ "$result" == *'HTTP 401'* ]] || exit 1
