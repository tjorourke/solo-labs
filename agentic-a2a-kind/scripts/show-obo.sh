#!/usr/bin/env bash
# show-obo.sh [user] — show the OBO token exchange, with the EXCHANGED token
# captured live off the wire.
#   1. the INBOUND Keycloak token for the user (sub=<user uuid>, groups, NO act)
#   2. the OBO public key the controller signs the EXCHANGED token with (/jwks.json)
#   3. the EXCHANGED token, captured on the controller→agent hop and decoded:
#        sub: <user uuid>     (preserved from the inbound token)
#        act.sub: system:serviceaccount:kagent:<agent>   (the acting agent)
#        aud: [kagent/<agent>]
#        iss: kagent.kagent   (signed by the key in 2; the header kid matches it)
#
# The exchanged token rides the controller→agent hop (when the controller proxies
# the inbound call to the agent pod on :8080). We sniff that hop with ngrep in an
# ephemeral container on the orchestrator pod while firing one call as the user.
# If the capture can't run (no debug perms / no image), we print the verified
# shape instead, clearly labelled.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
AS_USER="${1:-alice}"
AGENT="${AGENT:-sre-orchestrator}"
NETSHOOT_IMAGE="${NETSHOOT_IMAGE:-nicolaka/netshoot}"

# full_decode_jwt — print a JWT header AND payload as pretty JSON (decode_jwt in
# lib.sh only does the payload).
full_decode_jwt() {
  python3 - "$1" <<'PY'
import sys, json, base64
def d(seg):
    seg += "=" * (-len(seg) % 4)
    return json.loads(base64.urlsafe_b64decode(seg))
try:
    h, p, _ = sys.argv[1].split(".")
    print("header  " + json.dumps(d(h)))
    print("payload " + json.dumps(d(p), indent=2))
except Exception as e:
    print("(could not decode: %s)" % e); sys.exit(1)
PY
}

# pick_obo_token — from a list of captured JWTs (one per line on stdin), print the
# first whose payload carries an `act` claim (i.e. the exchanged OBO token).
# Uses `python3 -c` (not `python3 - <<HEREDOC`) so stdin stays the piped token
# list rather than being consumed as the program source.
pick_obo_token() {
  python3 -c '
import sys, json, base64
def payload(t):
    s = t.split(".")[1]; s += "=" * (-len(s) % 4)
    return json.loads(base64.urlsafe_b64decode(s))
for line in sys.stdin:
    t = line.strip()
    if not t: continue
    try:
        if "act" in payload(t):
            print(t); break
    except Exception:
        pass
'
}

step "1/3  Inbound Keycloak token for '${AS_USER}'  (the user's real login)"
kc -n "$KEYCLOAK_NS" port-forward svc/keycloak 18080:80 >/tmp/kc-pf.$$ 2>&1 & KPF=$!
for _ in $(seq 1 30); do curl -s -o /dev/null "http://localhost:18080/realms/${KEYCLOAK_REALM}/.well-known/openid-configuration" && break; sleep 1; done
TOKEN="$(curl -s -X POST "http://localhost:18080/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token" \
  -d "grant_type=password&client_id=${KEYCLOAK_CLIENT}&username=${AS_USER}&password=${AS_USER}" \
  | python3 -c 'import json,sys;print(json.load(sys.stdin).get("access_token",""))')"
kill $KPF 2>/dev/null
[[ -n "$TOKEN" ]] || die "could not mint ${AS_USER} token"
decode_jwt "$TOKEN" | sed 's/^/    /' >&2

step "2/3  OBO signer the controller exchanges into (/jwks.json)"
kc -n kagent port-forward svc/kagent-controller 8083:8083 >/tmp/c-pf.$$ 2>&1 & CPF=$!
trap 'kill $CPF 2>/dev/null' EXIT
for _ in $(seq 1 20); do curl -s -o /dev/null "http://localhost:8083/jwks.json" && break; sleep 1; done
curl -s http://localhost:8083/jwks.json | python3 -m json.tool 2>/dev/null | sed 's/^/    /' >&2 || warn "no /jwks.json"

step "3/3  The exchanged OBO token, captured on the controller→${AGENT} hop"

POD="$(kc -n kagent get pods -l app.kubernetes.io/name=${AGENT} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
CAP_OK=0
if [[ -n "$POD" ]]; then
  EC="obo-sniff-$$"
  log "starting an ngrep sniffer on ${POD} (ephemeral container)…"
  kc debug "$POD" -n kagent --image="$NETSHOOT_IMAGE" -q --profile=general --target=kagent -c "$EC" -- sleep 600 >/dev/null 2>&1 &
  __end=$(( $(date +%s) + 60 ))
  until kc -n kagent exec "$POD" -c "$EC" -- true 2>/dev/null; do
    [[ $(date +%s) -ge $__end ]] && break; sleep 2
  done
  if kc -n kagent exec "$POD" -c "$EC" -- true 2>/dev/null; then
    kc -n kagent exec "$POD" -c "$EC" -- \
      sh -c 'rm -f /tmp/obo.cap; setsid sh -c "ngrep -l -d any -W byline -q . tcp port 8080 > /tmp/obo.cap 2>&1" >/dev/null 2>&1 </dev/null & sleep 2' >/dev/null 2>&1
    log "firing one '${AS_USER}' call to generate the exchange…"
    for _ in $(seq 1 20); do curl -s -o /dev/null "http://localhost:8083/api/a2a/kagent/${AGENT}/.well-known/agent.json" && break; sleep 1; done
    curl -s -X POST "http://localhost:8083/api/a2a/kagent/${AGENT}/" \
      -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' --max-time 120 \
      -d '{"jsonrpc":"2.0","id":"1","method":"message/send","params":{"message":{"role":"user","parts":[{"kind":"text","text":"the orders database wont start - investigate"}],"messageId":"obo-show"}}}' \
      >/dev/null 2>&1 || true
    # ngrep block-buffers to a file; stop it first so the capture flushes, then read.
    sleep 1
    kc -n kagent exec "$POD" -c "$EC" -- pkill ngrep >/dev/null 2>&1 || true
    sleep 1
    OBO="$(kc -n kagent exec "$POD" -c "$EC" -- \
      sh -c "grep -aoiE 'eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+' /tmp/obo.cap 2>/dev/null | sort -u" 2>/dev/null \
      | pick_obo_token || true)"
    if [[ -n "$OBO" ]]; then
      CAP_OK=1
      ok "captured the exchanged token off the wire:"
      full_decode_jwt "$OBO" | sed 's/^/    /' >&2
      log "the header 'kid' above matches the /jwks.json key in step 2."
    fi
  fi
fi

if [[ "$CAP_OK" -ne 1 ]]; then
  warn "live capture unavailable (needs an ephemeral debug container + ${NETSHOOT_IMAGE}); showing the verified shape instead:"
  cat >&2 <<EOF
    {
      "iss": "kagent.kagent",
      "sub": "<${AS_USER}'s Keycloak sub uuid>",          # preserved from the inbound token
      "act": { "sub": "system:serviceaccount:kagent:${AGENT}" },
      "aud": ["kagent/${AGENT}"],
      "exp": "<+24h>"
    }
EOF
fi

cat >&2 <<EOF

    Same subject (the user's Keycloak sub, preserved); new issuer (kagent), a
    delegated act claim naming the acting agent, scoped audience, RS256-signed by
    the /jwks.json key. The controller sets this as the Authorization header when
    it proxies the inbound call to the agent pod.

    On the DIRECT agent→agent delegation (${AGENT}→dba-agent, pod to pod) there is
    no OBO bearer — identity rides as the headers x-user-id + x-kagent-source.
EOF
