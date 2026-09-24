#!/usr/bin/env bash
# One request, and every decision that shaped it, across both hops.
#
#   ./scripts/08-show-decision.sh bob "Review this function for concurrency bugs: ..."
#
# Sends the prompt as that user, then reads the identity out of the token, the task out of
# the router's log, OPA's decision out of its decision log, and the backend out of the
# decision gateway's access log.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/scripts/lib.sh"
load_tokens
USER_NAME="${1:-bob}"; PROMPT="${2:-Review this function for concurrency bugs: public void credit(long amt) { balance += amt; }}"
TOK_VAR="$(echo "$USER_NAME" | tr a-z A-Z)_TOKEN"; TOK="${!TOK_VAR:-}"
[ -n "$TOK" ] || { echo "error: no token for $USER_NAME (bob, alice, dave, badsig)" >&2; exit 1; }
gw_up
MARK="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; sleep 1
gw_curl "$TOK" "$(chat "$PROMPT")"
sleep 2
section() { echo; echo "$1"; printf '%*s\n' "${#1}" '' | tr ' ' '-'; }

section "IDENTITY (from the token the gateway verified)"
python3 -c 'import base64,json,sys; p=sys.argv[1].split(".")[1]; c=json.loads(base64.urlsafe_b64decode(p+"="*(-len(p)%4))); print("sub:", c["sub"])' "$TOK"

section "ROUTER, first hop (its log)"
kubectl -n "$NS" logs deploy/semantic-router --since-time="$MARK" | python3 -c '
import json, sys
for line in sys.stdin:
    try: d = json.loads(line)
    except Exception: continue
    if d.get("event") == "routing_decision":
        print("task:      " + str(d.get("selected_model")) + "   (decision " + str(d.get("decision") or d.get("reason_code")) + ")")
    if d.get("event") == "router_replay_start":
        print("signals:   " + json.dumps({k: v for k, v in d.get("signals", {}).items() if v}))'

section "AGW native decision (immediate audit event)"
kubectl -n "$NS" logs deploy/routing-audit --since-time="$MARK" | { grep '"decision_id"' || true; } | tail -1 | python3 -c '
import json, sys
line = sys.stdin.readline()
if not line.strip(): print("no decision logged"); sys.exit()
d = json.loads(line); r = d.get("result", {}); inp = d.get("input", {}).get("attributes", {})
sub = inp.get("metadataContext", {}).get("filterMetadata", {}).get("envoy.filters.http.jwt_authn", {}).get("jwt_payload", {}).get("sub")
print("verified sub:      " + str(sub))
print("task header seen:  " + str(inp.get("request", {}).get("http", {}).get("headers", {}).get("x-selected-model")))
r = json.loads(inp.get("request", {}).get("http", {}).get("headers", {}).get("x-agw-routing-decision", "{}"))
for k in ("status", "pool", "class", "reason"): print(f"{k + chr(58):19} {r.get(k)}")'

section "DECISION GATEWAY (access log)"
kubectl -n "$NS" logs deploy/decision-gateway --since-time="$MARK" \
  | { grep "http.path=/v1/chat/completions" || true; } | tail -1 \
  | grep -oE 'route=[^ ]+|endpoint=[^ ]+|http.status=[^ ]+|jwt.sub=[^ ]+|gen_ai.request.model=[^ ]+|gen_ai.response.model=[^ ]+' | sed 's/^/  /'

section "RESULT (what the client got back)"
echo "status:  $STATUS"
echo "task:    $(task)"
echo "pool:    $(pool)"
echo "class:   $(mclass)"
echo "reason:  $(reason)"
echo "model:   $(resp_model)"
