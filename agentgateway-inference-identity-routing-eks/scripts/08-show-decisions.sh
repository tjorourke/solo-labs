#!/usr/bin/env bash
# One request, and every decision that shaped it.
#
#   ./scripts/08-show-decisions.sh carol "Two writers report successful updates ... propose a safe write protocol."
#   ./scripts/08-show-decisions.sh alice "Explain optimistic concurrency control in two sentences."
#
# Sends the prompt as that user, then reads the identity out of the token, OPA's decision
# out of its decision log, the router's scores and decision out of its log, and the
# route and upstream out of the gateway's access log. Four sources, one request.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/scripts/lib.sh"
load_tokens
USER_NAME="${1:-carol}"; PROMPT="${2:-$HARD}"
TOK_VAR="$(echo "$USER_NAME" | tr a-z A-Z)_TOKEN"; TOK="${!TOK_VAR:-}"
[ -n "$TOK" ] || { echo "error: no token for $USER_NAME (alice, bob, carol, unknown, badsig)" >&2; exit 1; }
gw_up
MARK="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; sleep 1
gw_curl "$TOK" "$(chat "$PROMPT")"
sleep 2
section() { echo; echo "$1"; printf '%*s\n' "${#1}" '' | tr ' ' '-'; }

section "IDENTITY (from the token the gateway verified)"
python3 -c 'import base64,json,sys; p=sys.argv[1].split(".")[1]; c=json.loads(base64.urlsafe_b64decode(p+"="*(-len(p)%4))); print("sub:", c["sub"]); print("iss:", c["iss"])' "$TOK"

section "OPA (decision log)"
kubectl -n "$NS" logs deploy/opa --since-time="$MARK" | { grep '"decision_id"' || true; } | tail -1 | python3 -c '
import json, sys
line = sys.stdin.readline()
if not line.strip(): print("no decision logged"); sys.exit()
d = json.loads(line); r = d.get("result", {})
sub = d.get("input", {}).get("attributes", {}).get("metadataContext", {}).get("filterMetadata", {}).get("envoy.filters.http.jwt_authn", {}).get("jwt_payload", {}).get("sub")
print("verified sub seen by OPA:", sub)
if r.get("allowed"):
    for k, v in r["headers"].items(): print(f"{k.split(chr(45))[-1]:8} {v}")
else:
    print("denied:", r.get("http_status"), r.get("body"))'

section "SEMANTIC ROUTER (its log)"
kubectl -n "$NS" logs deploy/semantic-router --since-time="$MARK" | python3 -c '
import json, re, sys
for line in sys.stdin:
    m = re.search(r"Complexity rule .*difficulty=[a-z]+", line)
    if m: print(m.group(0)); continue
    try: d = json.loads(line)
    except Exception: continue
    if d.get("event") == "routing_decision":
        print("decision:       " + str(d.get("decision") or d.get("reason_code")))
        print("model in body:  " + str(d.get("original_model")) + " -> " + str(d.get("selected_model")))
    if d.get("event") == "router_replay_start":
        print("domain:         " + str(d.get("category")))'

section "GATEWAY (access log)"
kubectl -n "$NS" logs deploy/model-gateway --since-time="$MARK" \
  | { grep "http.path=/v1/chat/completions" || true; } | tail -1 \
  | grep -oE 'route=[^ ]+|endpoint=[^ ]+|http.status=[^ ]+|jwt.sub=[^ ]+|gen_ai.provider.name=[^ ]+|gen_ai.request.model=[^ ]+|gen_ai.response.model=[^ ]+' | sed 's/^/  /'

section "RESULT (what the client got back)"
echo "status:   $STATUS"
echo "target:   $(target)      (x-routing-target, from OPA)"
echo "class:    $(class)    (x-vsr-selected-model, from the router)"
echo "model:    $(resp_model)"
