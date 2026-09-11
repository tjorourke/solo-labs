#!/usr/bin/env bash
# ask.sh "<question>" — put a question to a hosted agent over kagent's OIDC-protected A2A
# endpoint, and watch it work.
#
# Two things the shared demo-4 ask.sh does not do:
#
#   1. It opens a kagent SESSION first and files the turn in it. A bare A2A call leaves
#      nothing behind: the UI lists conversations from stored sessions, and a turn with
#      no session is answered correctly and never seen again. The session id is printed,
#      and the same conversation is in the kagent UI under the agent, for the same user.
#   2. It uses message/stream, and prints each tool call as the agent makes it rather
#      than the whole trace after the answer. A Standard-mode run is seventeen calls
#      over a minute and a half; this is that minute and a half, visibly happening.
#
# The transcript keeps its shape, so check-report and trace-cost read it unchanged:
# "Trace (tools the agent called):", one numbered entry per call with its "-> " result,
# then the answer.
#
#   ask "Give me the release report for tjorourke/kagent, all open pull requests."
#   AGENT=releasejava ask "..."      # the other agent (a name prefix is enough)
#   AS_USER=bob ask "..."            # a different Keycloak user
#   ASK_TRACE=0 ask "..."            # the answer only
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../demo-scripts/agentregistry/scripts/lib.sh
source "$HERE/../../../demo-scripts/agentregistry/scripts/lib.sh"

PREFIX="${AGENT:-prtriagejava}"
AGENT_NAME="$(resolve_kagent_agent "$PREFIX")"
[[ -n "$AGENT_NAME" ]] || { die "no kagent Agent matching '$PREFIX' — is it deployed?"; exit 1; }
PROMPT="${*:-Give me the release report for ${DEMO_REPO:-tjorourke/kagent}, all open pull requests.}"

# The token mint and the A2A call run inside a pod, so nothing here needs a port-forward
# and it behaves the same in a terminal and in a notebook cell. That pod needs python3,
# which the Java agents do not have, so use any pod in the namespace that does.
pick_exec_pod() {
  local candidate
  for candidate in $(kc -n kagent get pods --field-selector=status.phase=Running -o name 2>/dev/null); do
    candidate="${candidate#pod/}"
    if kc -n kagent exec "$candidate" -- sh -c 'command -v python3 >/dev/null 2>&1' 2>/dev/null; then
      echo "$candidate"; return
    fi
  done
  die "no pod in the kagent namespace has python3, which ask needs to mint the token"; exit 1
}
POD="$(pick_exec_pod)" || exit 1

echo "Asking '$AGENT_NAME' as $AS_USER (OIDC) ..."
# Mint from the in-cluster Keycloak URL; KC_HOSTNAME stamps the browser-facing issuer on
# the token, which is the one the controller validates.
ISSUER="${KEYCLOAK_MINT_URL:-http://keycloak.${KEYCLOAK_NS}.svc.cluster.local:8080/realms/${KEYCLOAK_REALM}}"
kc -n kagent exec -i "$POD" -- python3 -u - "$AGENT_NAME" "$AS_USER" "$PROMPT" "$ISSUER" \
    "$KAGENT_CLI_CLIENT" "$AS_PASSWORD" "${ASK_TRACE:-1}" kagent <<'PY'
import sys, json, time, urllib.request, urllib.parse
agent, user, prompt, issuer, client, password, trace, ns = sys.argv[1:9]
trace = trace != "0"
tok = json.load(urllib.request.urlopen(issuer + "/protocol/openid-connect/token",
      urllib.parse.urlencode({"grant_type": "password", "client_id": client,
                              "username": user, "password": password}).encode()))["access_token"]
base = "http://kagent-controller.kagent.svc.cluster.local:8083"
auth = {"Authorization": "Bearer " + tok, "Content-Type": "application/json"}

# 1. a session, so the turn has somewhere to live. Same user as the token, so it is the
#    same person's conversation in the UI.
session = None
try:
    r = urllib.request.urlopen(urllib.request.Request(base + "/api/sessions",
        json.dumps({"agent_ref": "%s/%s" % (ns, agent), "name": prompt[:60]}).encode(), auth), timeout=20)
    session = json.load(r)["data"]["id"]
    print("session   %s   (the same conversation is in the kagent UI)" % session, flush=True)
except Exception as e:
    print("  ! could not open a kagent session (%s); this turn will not appear in the UI" % e, flush=True)

# 2. the question, streamed
message = {"role": "user", "parts": [{"kind": "text", "text": prompt}], "messageId": "ask-%d" % int(time.time())}
if session:
    message["contextId"] = session
body = json.dumps({"jsonrpc": "2.0", "id": "1", "method": "message/stream",
                   "params": {"message": message}}).encode()
req = urllib.request.Request(base + "/api/a2a/%s/%s/" % (ns, agent), body,
                             dict(auth, Accept="text/event-stream"))
try:
    resp = urllib.request.urlopen(req, timeout=300)
except urllib.error.HTTPError as e:
    print("\nA2A error: HTTP %d %s" % (e.code, e.read().decode(errors="replace")[:500])); sys.exit(1)

def shown(response):
    """The part of a tool result worth printing: the payload the model saw."""
    if not isinstance(response, dict):
        return response
    sc = response.get("structuredContent")
    if isinstance(sc, dict) and "result" in sc:
        return sc["result"]
    if "result" in response:
        return response["result"]
    content = response.get("content")
    if isinstance(content, list):
        text = " ".join(str(x.get("text", "")) for x in content if isinstance(x, dict))
        return text or json.dumps(response)
    return json.dumps(response)

def fmt_args(args):
    if not isinstance(args, dict):
        return json.dumps(args)
    return ", ".join("%s=%s" % (k, json.dumps(v) if isinstance(v, (list, dict)) else v) for k, v in args.items())

calls, numbered, answer, error, header = 0, {}, "", None, False
def frame(text):
    global calls, answer, error, header
    result = text.get("result")
    if result is None:
        error = text.get("error", text); return True
    kind = result.get("kind")
    if kind == "artifact-update":
        for p in result.get("artifact", {}).get("parts", []):
            if p.get("kind") == "text": answer = p["text"]
        return False
    if kind != "status-update":
        return False
    status = result.get("status", {})
    msg = status.get("message") or {}
    if msg.get("role") == "agent":
        for p in msg.get("parts", []):
            if p.get("kind") == "text" and p.get("text", "").strip() and status.get("state") == "working":
                answer = p["text"]
            if p.get("kind") == "data" and trace:
                data = p.get("data", {})
                if "args" in data:
                    if not header:
                        print("\nTrace (tools the agent called):", flush=True); header = True
                    calls += 1; numbered[data.get("id") or calls] = calls
                    print("  %d. %s(%s)" % (calls, data.get("name"), fmt_args(data.get("args"))), flush=True)
                elif "response" in data:
                    n = numbered.get(data.get("id"), calls)
                    print("     -> %s" % shown(data["response"]), flush=True)
    return bool(result.get("final"))

buf = []
for raw in resp:
    line = raw.decode(errors="replace").rstrip("\r\n")
    if line.startswith("data:"):
        buf.append(line[5:].strip()); continue
    if line == "" and buf:
        try:
            done = frame(json.loads("".join(buf)))
        except json.JSONDecodeError:
            done = False
        buf = []
        if done: break
if error is not None:
    print("\nA2A error: " + json.dumps(error)[:500]); sys.exit(1)
print("\n" + (answer if answer.strip() else "(the agent returned no text)"))
PY
