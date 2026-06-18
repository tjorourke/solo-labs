#!/usr/bin/env bash
# 04-backend.sh — create the app namespace, the AWS creds Secret the bedrock
# provider authenticates with, and the AgentgatewayBackend + HTTPRoute.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib.sh"
require_aws

step "Namespace $NS"
kctx create ns "$NS" --dry-run=client -o yaml | kctx apply -f - >/dev/null; ok "ns ready"

step "AWS creds Secret $NS/$SECRET (accessKey/secretKey/sessionToken)"
CREDS_JSON="$(aws configure export-credentials --format process)"
AK="$(echo "$CREDS_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin)["AccessKeyId"])')"
SK="$(echo "$CREDS_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin)["SecretAccessKey"])')"
ST="$(echo "$CREDS_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("SessionToken",""))')"
# Only include sessionToken when the creds actually have one. Static IAM-user
# creds have none; an empty token makes the gateway sign with an empty
# X-Amz-Security-Token and Bedrock returns 403 "security token invalid".
ST_ARG=(); [[ -n "$ST" ]] && ST_ARG=(--from-literal=sessionToken="$ST")
kctx -n "$NS" create secret generic "$SECRET" \
  --from-literal=accessKey="$AK" --from-literal=secretKey="$SK" "${ST_ARG[@]}" \
  --dry-run=client -o yaml | kctx apply -f - >/dev/null
ok "Secret applied ($([[ -n "$ST" ]] && echo 'with session token' || echo 'static creds'); re-run to refresh)"

step "Bedrock backend + route (region=$REGION)"
export REGION NS GW_NS SECRET
envsubst < "$LAB_ROOT/yaml/backend-route.yaml.tmpl" | kctx apply -f - >/dev/null
kctx -n "$NS" get agentgatewaybackend bedrock -o wide >&2
kctx -n "$NS" wait --for=condition=Accepted agentgatewaybackend/bedrock --timeout=60s >/dev/null 2>&1 || true
ok "backend + route applied"

# The proxy reads the AWS creds Secret at startup, so it must restart to pick up
# the Secret we just wrote (it was created/refreshed after the proxy came up).
# Without this you get HTTP 403 "security token included in the request is invalid".
step "Restarting the proxy to load the AWS credentials"
kctx -n "$GW_NS" rollout restart deploy/agentgateway-proxy >/dev/null 2>&1 || true
kctx -n "$GW_NS" rollout status deploy/agentgateway-proxy --timeout=120s >/dev/null 2>&1 || true
ok "proxy reloaded"
echo "  Next: ./scripts/05-test.sh" >&2
