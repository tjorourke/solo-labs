#!/usr/bin/env bash
# test.sh — exercise the gateway over the Anthropic Messages API. Requires the
# port-forward from demo.sh to be running on localhost:$PORT. Three scenarios:
#   1. no JWT            -> 401 (jwtAuthentication: Strict)
#   2. wrong team JWT    -> 403 (authorization CEL)
#   3. authorized JWT    -> 200, OpenAI answer returned in Anthropic format
#
# The request body is a real Anthropic Messages payload — exactly what Claude
# Code sends — so a reader can reproduce every case by hand.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

BASE="http://localhost:${PORT}"
BODY='{"model":"claude-3-5-sonnet-20241022","max_tokens":128,"messages":[{"role":"user","content":"In one sentence, what is an API gateway?"}]}'

req() { # $1=label  $2=auth-header-or-empty
  local label="$1" auth="$2"
  step "$label"
  if [[ -n "$auth" ]]; then
    curl -sS -o /tmp/cc_resp.json -w 'HTTP %{http_code}\n' \
      "$BASE/v1/messages" \
      -H 'content-type: application/json' \
      -H 'anthropic-version: 2023-06-01' \
      -H "Authorization: Bearer $auth" \
      -d "$BODY" >&2
  else
    curl -sS -o /tmp/cc_resp.json -w 'HTTP %{http_code}\n' \
      "$BASE/v1/messages" \
      -H 'content-type: application/json' \
      -H 'anthropic-version: 2023-06-01' \
      -d "$BODY" >&2
  fi
  if command -v jq >/dev/null 2>&1; then jq . /tmp/cc_resp.json >&2 2>/dev/null || cat /tmp/cc_resp.json >&2; else cat /tmp/cc_resp.json >&2; fi
  echo >&2
}

req "1. No JWT — expect 401" ""
req "2. Wrong team (team=marketing) — expect 403" "$("$SCRIPT_DIR/mint-token.sh" marketing)"
req "3. Authorized (org=acme, team=data-platform) — expect 200, Anthropic-shaped reply from OpenAI" "$("$SCRIPT_DIR/mint-token.sh")"

step "Observability — last lines of the proxy access log (model + token usage + trace id)"
kctx -n "$GW_NS" logs -l app.kubernetes.io/name=agentgateway --tail=5 2>/dev/null | sed 's/^/  /' >&2 \
  || kctx -n "$GW_NS" logs "deploy/$GW_NAME" --tail=5 2>/dev/null | sed 's/^/  /' >&2 || true
