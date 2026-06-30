#!/usr/bin/env bash
# capture-keys.sh — prove the per-team static-key swap end to end.
#
#   - mint a sales JWT and an engineering JWT from the mock IdP
#   - send each through the gateway; the echo upstream reports which static key
#     agentgateway injected (sales key vs engineering key)
#   - show that a missing JWT is rejected, and a spoofed x-team is overwritten

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

GW="${GW:-18080}"; IDP="${IDP:-18088}"

step "Port-forwarding gateway:$GW and mock-idp:$IDP"
kc -n agentgateway-system port-forward svc/teamkey-gateway "${GW}:80" >/dev/null &
PF1=$!
kc -n teamkey-demo port-forward svc/mock-idp "${IDP}:8080" >/dev/null &
PF2=$!
cleanup() { kill "$PF1" "$PF2" 2>/dev/null || true; }
trap cleanup EXIT INT TERM
sleep 4

mint() { curl -s --max-time 15 "http://localhost:${IDP}/token?team=$1&sub=$2" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])"; }

call() { # $1 label, $2 token, $3 extra-header(optional)
  step "$1"
  local hdr="${3:-}"
  if [[ -n "$hdr" ]]; then
    curl -s --max-time 30 -o /tmp/teamkey-body.json -w 'HTTP %{http_code}\n' \
      "http://localhost:${GW}/v1/chat/completions" -H 'content-type: application/json' \
      -H "Authorization: Bearer $2" -H "$hdr" \
      -d '{"model":"echo","messages":[{"role":"user","content":"hello"}]}' >&2
  else
    curl -s --max-time 30 -o /tmp/teamkey-body.json -w 'HTTP %{http_code}\n' \
      "http://localhost:${GW}/v1/chat/completions" -H 'content-type: application/json' \
      -H "Authorization: Bearer $2" \
      -d '{"model":"echo","messages":[{"role":"user","content":"hello"}]}' >&2
  fi
  python3 -c "import json;d=json.load(open('/tmp/teamkey-body.json'));print('  upstream reply:',d['choices'][0]['message']['content'])" 2>/dev/null \
    || { echo "  raw:" >&2; head -c 300 /tmp/teamkey-body.json >&2; echo >&2; }
}

SALES_JWT="$(mint sales tom)"
ENG_JWT="$(mint engineering ram)"

call "1. Tom's JWT (team=sales) → expect SALES key injected" "$SALES_JWT"
call "2. Ram's JWT (team=engineering) → expect ENGINEERING key injected" "$ENG_JWT"
call "3. Sales JWT but spoofed 'x-team: engineering' → still routed by the verified claim (sales)" "$SALES_JWT" "x-team: engineering"

step "4. No JWT → expect 401 from the gateway"
curl -s --max-time 15 -o /dev/null -w '  HTTP %{http_code}\n' \
  "http://localhost:${GW}/v1/chat/completions" -H 'content-type: application/json' \
  -d '{"model":"echo","messages":[{"role":"user","content":"hello"}]}' >&2

step "What the upstream actually received (echo /seen)"
kc -n teamkey-demo exec deploy/echo-upstream -- \
  python -c "import urllib.request,json;print(json.dumps(json.load(urllib.request.urlopen('http://localhost:8080/seen?limit=5')),indent=2))" 2>/dev/null >&2 \
  || warn "could not read echo /seen"

step "Done"
