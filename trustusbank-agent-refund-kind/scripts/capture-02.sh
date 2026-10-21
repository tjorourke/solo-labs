#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
tools
# The default ServiceAccount is not on the L4 allow-list.
set +e
result=$(incurl --connect-timeout 4 http://ledger-agent.bank.svc.cluster.local:8080 2>&1)
rc=$?
set -e
printf 'Unknown pod, exit=%s: %s\n' "$rc" "$result"
[[ "$rc" != 0 ]] || exit 1
k -n bank run authorised --image=curlimages/curl:8.10.1 --restart=Never --overrides='{"spec":{"serviceAccountName":"orchestrator"}}' --dry-run=client -o yaml --command -- sh -c 'trap "exit 0" TERM INT; sleep 86400 & wait' | apply_stdin
trap 'k -n bank delete pod authorised --ignore-not-found --wait=false >/dev/null' EXIT
k -n bank wait --for=condition=Ready pod/authorised --timeout=120s >/dev/null
k -n bank exec authorised -- curl --fail --max-time 10 -sS -o /dev/null -w 'Authorised workload HTTP %{http_code}\n' http://ledger-agent:8080/.well-known/agent-card.json
