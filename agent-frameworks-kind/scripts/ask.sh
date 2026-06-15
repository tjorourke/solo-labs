#!/usr/bin/env bash
# ask.sh "<prompt>" — call the SRE orchestrator AS a Keycloak user (default
# alice) and print the agent's reply. The controller validates the user's token
# (OIDC), authorizes by her group, and mints a kagent OBO token (sub: <user>,
# act.sub: <agent SA>) for the downstream agent hops.
#
#   ./scripts/ask.sh "the orders database won't start - investigate and fix"
#   AS_USER=bob ./scripts/ask.sh "..."     # different identity
# (NB: AS_USER, not USER — USER is your login name.)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

AGENT="${AGENT:-sre-orchestrator}"; AS_USER="${AS_USER:-alice}"
if [[ "$#" -gt 0 ]]; then PROMPT="$*"; elif [[ ! -t 0 ]]; then PROMPT="$(cat)"; else PROMPT="the orders database won't start - investigate and tell me the fix"; fi
PROMPT="$(printf '%s' "$PROMPT" | tr '\n' ' ' | sed 's/  */ /g')"

# ── 1. mint the user's Keycloak token (own port-forward, then release it) ──────
step "1/2  ${AS_USER}'s Keycloak token (inbound)"
kc -n "$KEYCLOAK_NS" port-forward svc/keycloak 18080:80 >/tmp/kc-pf.$$ 2>&1 & KPF=$!
for _ in $(seq 1 30); do curl -s -o /dev/null "http://localhost:18080/realms/${KEYCLOAK_REALM}/.well-known/openid-configuration" && break; sleep 1; done
TOKEN="$(curl -s -X POST "http://localhost:18080/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d "grant_type=password&client_id=${KEYCLOAK_CLIENT}&username=${AS_USER}&password=${AS_USER}" \
  | python3 -c 'import json,sys;print(json.load(sys.stdin).get("access_token",""))')"
kill $KPF 2>/dev/null
[[ -n "$TOKEN" ]] || die "could not mint ${AS_USER} token (is Keycloak up?)"
log "claims (note: sub=${AS_USER}, has groups, NO act):"; decode_jwt "$TOKEN" | sed 's/^/    /' >&2

# ── 2. call the orchestrator as the user ──────────────────────────────────────
step "2/2  Calling ${AGENT} as ${AS_USER} (Authorization: Bearer <${AS_USER}>)"
kc -n kagent port-forward svc/kagent-controller 8083:8083 >/tmp/a2a-pf.$$ 2>&1 & CPF=$!
trap 'kill $CPF 2>/dev/null' EXIT
for _ in $(seq 1 20); do curl -s -o /dev/null "http://localhost:8083/api/a2a/kagent/${AGENT}/.well-known/agent.json" && break; sleep 1; done
RESP="$(curl -s -X POST "http://localhost:8083/api/a2a/kagent/${AGENT}/" \
  -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' --max-time 240 \
  -d "{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"message/send\",\"params\":{\"message\":{\"role\":\"user\",\"parts\":[{\"kind\":\"text\",\"text\":$(printf '%s' "$PROMPT" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')}],\"messageId\":\"ask-$$\"}}}")"
echo "" >&2
printf '%s' "$RESP" | python3 -c '
import sys,json
try: d=json.load(sys.stdin)
except Exception: print(sys.stdin.read()[:1500]); sys.exit()
if "error" in d: print("A2A error:", json.dumps(d["error"])); sys.exit()
seen=[]
def w(o):
    if isinstance(o,dict):
        if o.get("kind")=="text" and isinstance(o.get("text"),str):
            t=o["text"].strip()
            if t and t not in seen: seen.append(t)
        [w(v) for v in o.values()]
    elif isinstance(o,list): [w(v) for v in o]
w(d.get("result",d)); print("\n\n".join(seen) if seen else json.dumps(d)[:1500])
'
echo "" >&2
log "To SEE the exchanged OBO token (sub: ${AS_USER}, act.sub: <agent>):  ./scripts/show-obo.sh ${AS_USER}" >&2
