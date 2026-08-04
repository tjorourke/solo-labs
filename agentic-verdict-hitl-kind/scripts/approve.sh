#!/usr/bin/env bash
# approve.sh — approve or reject a DECLARATIVE agent's pending tool call over the
# kagent A2A API, without touching the UI.
#
#   ./scripts/approve.sh srenative "restart the checkout deployment in shop"
#   ./scripts/approve.sh srenative "scale checkout to 0" reject
#
# This is the same call the kagent UI makes when you click Approve. There is no
# separate "approvals" REST resource in kagent: an approval IS a follow-up A2A
# message on the same task, carrying a function_response DataPart that sets
# toolConfirmation.confirmed.
#
# The wire flow, which this script walks in two steps:
#
#   1. message/send  ->  task comes back with status.state = "input-required" and a
#      DataPart:  { name: "adk_request_confirmation",
#                   id: "adk-<uuid>",
#                   args: { originalFunctionCall: {...},
#                           toolConfirmation: { confirmed: false, hint: "..." } } }
#
#   2. message/send  ->  same taskId + contextId, one DataPart:
#      { metadata: { kagent_type: "function_response" },
#        data: { id: "<the adk- id from step 1>",
#                name: "adk_request_confirmation",
#                response: { confirmed: true } } }
#      Task goes to "completed" and the tool runs.
#
# Note the response shape is just { confirmed: <bool> }. Echoing the whole
# toolConfirmation object back instead sends the task to "failed".
#
# BYO agents cannot use this. kagent knows nothing about a call parked at the
# gateway, so there is no task in input-required state to respond to — use
# the Solo Enterprise UI, which sends exactly the same A2A message.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

AGENT="${1:-$NATIVE_AGENT}"
PROMPT="${2:-restart the checkout deployment in shop}"
DECISION="${3:-approve}"

kc -n "$KAGENT_NS" get agent "$AGENT" >/dev/null 2>&1 \
  || die "no kagent Agent '$AGENT'"
TYPE="$(kc -n "$KAGENT_NS" get agent "$AGENT" -o jsonpath='{.spec.type}' 2>/dev/null)"
# Works for BOTH agent types. A Declarative agent gets requireApproval on its tool
# stanza; a BYO agent gets KAGENT_REQUIRE_APPROVAL in its env, which its ADK toolsets
# turn into the same native confirmation. Either way the approval is a kagent task in
# input-required state, so the same A2A call decides it.
log "agent type: ${TYPE:-unknown}"

POD="$(kc -n "$KAGENT_NS" get pods -l "app.kubernetes.io/name=$AGENT" -o name 2>/dev/null | head -1)"
[[ -n "$POD" ]] || die "no running pod for '$AGENT'"

CONFIRM=true
[[ "$DECISION" == "reject" || "$DECISION" == "deny" ]] && CONFIRM=false

step "Asking '$AGENT', then submitting a ${DECISION} over the A2A API"
log "prompt: $PROMPT"

ISSUER="http://keycloak.${KEYCLOAK_NS}.svc.cluster.local:8080/realms/${KEYCLOAK_REALM}"

kc -n "$KAGENT_NS" exec -i "${POD#*/}" -- python3 - \
  "$AGENT" "$AS_USER" "$AS_PASSWORD" "$PROMPT" "$ISSUER" "$KAGENT_NS" "$CONFIRM" <<'PY'
import json, sys, urllib.request, urllib.parse

agent, user, password, prompt, issuer, ns, confirm = sys.argv[1:8]
confirm = confirm == "true"

tok = json.load(urllib.request.urlopen(
    issuer + "/protocol/openid-connect/token",
    urllib.parse.urlencode({"grant_type": "password", "client_id": "kagent-cli-password",
                            "username": user, "password": password}).encode()))["access_token"]

URL = "http://kagent-controller.%s.svc.cluster.local:8083/api/a2a/%s/%s/" % (ns, ns, agent)


def send(body):
    req = urllib.request.Request(URL, json.dumps(body).encode(),
                                 {"Authorization": "Bearer " + tok,
                                  "Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=300))


# ── 1. ask, and expect the task to stop for approval ─────────────────────────
r = send({"jsonrpc": "2.0", "id": "1", "method": "message/send",
          "params": {"message": {"role": "user", "messageId": "ask-1",
                                 "parts": [{"kind": "text", "text": prompt}]}}})
r = r.get("result", r)
task, ctx = r.get("id"), r.get("contextId")
state = r.get("status", {}).get("state")

confs = [p["data"] for m in (r.get("history") or []) + [r.get("status", {}).get("message") or {}]
         for p in (m.get("parts") or [])
         if p.get("kind") == "data" and p.get("data", {}).get("name") == "adk_request_confirmation"]

if not confs:
    print("\nNo approval was requested (task state: %s)." % state)
    print("Either the agent chose not to call a gated tool, or it is not marked red.")
    raise SystemExit(0)

c = confs[0]
call = c["args"]["originalFunctionCall"]
print("\n  task state   : %s" % state)
print("  tool         : %s(%s)" % (call["name"],
      ", ".join("%s=%s" % kv for kv in (call.get("args") or {}).items())))
print("  hint         : %s" % c["args"]["toolConfirmation"].get("hint", ""))
print("  confirmation : %s" % c["id"])

# ── 2. decide, on the SAME task ──────────────────────────────────────────────
# The response payload is just {confirmed: bool}. Echoing the whole
# toolConfirmation object back sends the task to "failed" instead.
print("\n  -> sending %s" % ("APPROVE" if confirm else "REJECT"))
r2 = send({"jsonrpc": "2.0", "id": "2", "method": "message/send",
           "params": {"message": {
               "role": "user", "taskId": task, "contextId": ctx, "messageId": "decide-1",
               "parts": [{"kind": "data",
                          "metadata": {"kagent_type": "function_response"},
                          "data": {"id": c["id"], "name": "adk_request_confirmation",
                                   "response": {"confirmed": confirm}}}]}}})
r2 = r2.get("result", r2)
print("  task state   : %s" % r2.get("status", {}).get("state"))

texts = [p["text"] for m in (r2.get("history") or []) if m.get("role") == "agent"
         for p in (m.get("parts") or []) if p.get("kind") == "text" and p.get("text")]
if texts:
    print("\nAgent:\n%s" % texts[-1].strip())
PY

step "Tool server state"
kc -n "$SRE_NS" exec deploy/sre-tools -- python3 -c "
import urllib.request, json
d = json.load(urllib.request.urlopen('http://localhost:8080/state', timeout=5))
print('  audit entries :', len(d['audit']), '(0 = the tool never ran)')
c = d['deployments']['checkout']
print('  checkout      :', c['ready'], '/', c['replicas'], 'ready')
" 2>/dev/null || warn "could not read the tool server state"
