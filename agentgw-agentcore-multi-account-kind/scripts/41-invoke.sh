#!/usr/bin/env bash
# 41-invoke.sh — the proof. Mint a Keycloak token, then call all four agents
# through the ONE gateway: two AWS accounts, two regions, one data plane. Also
# proves the negative (no token -> 401). AgentCore replies over the A2A
# JSON-RPC protocol; the prompt asks for a die roll so the tools actually run.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
load_tofu_env

PROMPT="${PROMPT:-Roll a 20-sided die and tell me if the result is prime.}"
PAYLOAD="$(PROMPT="$PROMPT" python3 -c 'import json,os;print(json.dumps({"jsonrpc":"2.0","id":"r1","method":"message/send","params":{"message":{"role":"user","messageId":"m1","parts":[{"kind":"text","text":os.environ["PROMPT"]}]}}}))')"

step "Minting a caller token (admin-user via Keycloak)"
TOKEN="$(mint_user_token)"
[[ -n "$TOKEN" ]] || die "could not mint a token from ${KEYCLOAK_ISSUER}"
ok "token minted (sub -> STS session name in each account's CloudTrail)"

step "Negative test: no token -> 401"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://${AGENTS_HOST}/portfolio-a/poet" \
  -H 'Content-Type: application/json' -d "$PAYLOAD")"
[[ "$CODE" == "401" ]] && ok "unauthenticated request rejected with 401" \
  || warn "expected 401 without a token, got $CODE"

invoke() { # invoke <env> <agent>
  local env="$1" agent="$2" out code
  out="$(mktemp)"
  code="$(curl -s -o "$out" -w '%{http_code}' -X POST "http://${AGENTS_HOST}/${env}/${agent}" \
    -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
    --max-time 120 -d "$PAYLOAD")"
  if [[ "$code" == "200" ]]; then
    local text
    text="$(jq -r '[.. | objects | select(.kind=="text") | .text] | last // empty' "$out" 2>/dev/null)"
    [[ -n "$text" ]] || text="$(head -c 300 "$out")"
    ok "${env}/${agent} [200]"
    printf '      %s\n' "$text" | head -4 >&2
  else
    warn "${env}/${agent} returned $code"
    head -c 400 "$out" >&2; echo >&2
  fi
  rm -f "$out"
  [[ "$code" == "200" ]]
}

FAILED=0
step "Invoking all four agents through the single gateway"
invoke portfolio-a poet  || FAILED=1
invoke portfolio-a quant || FAILED=1
invoke portfolio-b poet  || FAILED=1
invoke portfolio-b quant || FAILED=1

[[ "$FAILED" == 0 ]] && step "All four agents answered: two accounts, two regions, one gateway" \
  || die "one or more invokes failed — check the proxy logs: kc -n $GW_NS logs deploy/$GW_NAME | tail -50"
echo "  Next: ./scripts/50-cloudtrail.sh (evidence) and ./scripts/51-mismatch-demo.sh (optional)" >&2
