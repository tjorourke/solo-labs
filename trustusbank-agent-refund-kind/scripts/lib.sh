#!/usr/bin/env bash
set -Eeuo pipefail
LAB=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$LAB/versions.env"
CTX=kind-trustusbank-lab
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
KC=http://keycloak.keycloak.svc.cluster.local:8080/realms/bank/protocol/openid-connect/token
STS=http://enterprise-agentgateway.agentgateway-system.svc.cluster.local:7777
GW=http://bank-gw.bank.svc.cluster.local:8080
user_token() { incurl "$KC" -d grant_type=password -d client_id=payments-ops -d username=bob -d password=password | access_token; }
access_token() { python3 -c 'import json,sys; d=json.load(sys.stdin); assert "access_token" in d,d; print(d["access_token"])'; }
exchange() {
  incurl "$STS/oauth2/token" -d grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
    -d subject_token_type=urn:ietf:params:oauth:token-type:jwt -d "subject_token=$1" \
    -d actor_token_type=urn:ietf:params:oauth:token-type:jwt -d "actor_token=$2" -d "audience=$3"
}
claims() { python3 -c 'import base64,json,sys;p=sys.stdin.read().strip().split(".")[1];print(json.dumps(json.loads(base64.urlsafe_b64decode(p+"="*(-len(p)%4))),indent=2))'; }
chain() {
  U=$(user_token)
  O=$(k -n bank create token orchestrator --duration=10m)
  L=$(k -n bank create token ledger-agent --duration=10m)
  H1=$(exchange "$U" "$O" ledger-agent | access_token)
  H2=$(exchange "$H1" "$L" payments-mcp | access_token)
}
