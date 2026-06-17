#!/usr/bin/env bash
# demo.sh — drive the same seven routing scenarios as part 1, against the
# agentgateway proxy:
#   1. no header / no token              -> default to latest
#   2. x-version-override: v2            -> v2     (explicit client/ops header)
#   3. x-tenant-version: v2 (client)     -> ?      (does AGW strip the claim header?)
#   4. JWT version=v2                    -> v2     (claim projected + re-routed)
#   5. JWT version=latest                -> latest
#   6. JWT version=v2 + override=latest  -> latest (explicit override beats the claim)
#   7. invalid JWT                       -> 401    (Optional still rejects bad tokens)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

PORT="${PORT:-8088}"
BASE="http://localhost:${PORT}"

# the auto-provisioned proxy Service is named after the Gateway
SVC="${SVC:-$GW_NAME}"

step "Port-forwarding the agentgateway proxy (svc/$SVC) → localhost:${PORT}"
kctx "$EDGE_CTX" -n "$GW_NS" port-forward "svc/$SVC" "${PORT}:80" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT
for _ in $(seq 1 20); do
  curl -fsS -o /dev/null "$BASE/" 2>/dev/null && break
  sleep 1
done
ok "port-forward up (pid $PF_PID)"

served_by() {
  local body; body="$(curl -fsS "$@" "$BASE/" 2>/dev/null || true)"
  if [[ -z "$body" ]]; then echo "    (no body / non-2xx)"; return; fi
  local served xtv
  served="$(printf '%s' "$body" | jq -r '.servedBy // "?"' 2>/dev/null)"
  xtv="$(printf '%s' "$body" | jq -r '.headers["x-tenant-version"] // "(none)"' 2>/dev/null)"
  echo "    servedBy=${served}   backend saw x-tenant-version=${xtv}"
}

http_code() { curl -s -o /dev/null -w '%{http_code}' "$@" "$BASE/" 2>/dev/null; }

TOKEN_V2="$("$SCRIPT_DIR/mint-token.sh" v2 acme)"
TOKEN_LATEST="$("$SCRIPT_DIR/mint-token.sh" latest beta)"

step "1. No header, no token  (expect: default to latest)"
served_by

step "2. x-version-override: v2  (explicit client/ops header -> v2)"
served_by -H "x-version-override: v2"

step "3. Client sends x-tenant-version: v2  (does AGW strip the claim header?)"
served_by -H "x-tenant-version: v2"

step "4. JWT version=v2  (claim projected + re-routed -> v2)"
served_by -H "Authorization: Bearer $TOKEN_V2"

step "5. JWT version=latest  (-> latest)"
served_by -H "Authorization: Bearer $TOKEN_LATEST"

step "6. JWT version=v2 + x-version-override: latest  (override beats the claim -> latest)"
served_by -H "Authorization: Bearer $TOKEN_V2" -H "x-version-override: latest"

step "7. Invalid JWT  (expect: 401)"
echo "    HTTP $(http_code -H 'Authorization: Bearer not.a.jwt')"

step "Done"
echo "  Tear down AGW (keep clusters):  ./scripts/quick.sh teardown" >&2
