#!/usr/bin/env bash
set -Eeuo pipefail
LAB=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$LAB/versions.env"
CTX=kind-trustusbank-lab
export SECRETS_FILE="${SECRETS_FILE:-$HOME/.config/solo/refund-lab.env}"
k() { kubectl --context "$CTX" "$@"; }
apply() { k apply --dry-run=server -f "$1" >/dev/null; k apply -f "$1"; }
apply_stdin() { local tmp; tmp=$(mktemp); chmod 600 "$tmp"; cat > "$tmp"; apply "$tmp"; rm -f "$tmp"; }
restart_deployment() {
  local patch
  patch=$(printf '{"spec":{"template":{"metadata":{"annotations":{"kubectl.kubernetes.io/restartedAt":"%s"}}}}}' "$(date -u +%Y-%m-%dT%H:%M:%SZ)")
  k -n "$1" patch deployment "$2" --type=merge -p "$patch" --dry-run=server >/dev/null || return 1
  k -n "$1" patch deployment "$2" --type=merge -p "$patch"
}
tools() {
  if ! k -n bank get pod tools >/dev/null 2>&1; then
    k -n bank run tools --image=curlimages/curl:8.10.1 --restart=Never --dry-run=client -o yaml --command -- sleep 86400 | apply_stdin
  fi
  k -n bank wait --for=condition=Ready pod/tools --timeout=180s >/dev/null
}
incurl() { k -n bank exec tools -- curl --max-time "${CURL_MAX_TIME:-25}" -sS "$@"; }
core_probe() {
  k -n bank exec deployment/payments-mcp -- python -c '
import urllib.request, urllib.error, json
try:
 r=urllib.request.urlopen(urllib.request.Request("http://bank-gw.bank.svc.cluster.local:8080/core",data=b"{}",headers={"Content-Type":"application/json"}),timeout=15)
except urllib.error.HTTPError as e: r=e
print(r.read().decode()); print("HTTP",r.code)'
}
KC=http://keycloak.keycloak.svc.cluster.local:8080/realms/bank/protocol/openid-connect/token
STS=http://enterprise-agentgateway.agentgateway-system.svc.cluster.local:7777
