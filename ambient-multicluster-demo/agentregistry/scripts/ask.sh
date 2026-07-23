#!/usr/bin/env bash
# ask.sh "<prompt>" — ask the hosted agent through kagent's OIDC-protected A2A
# endpoint, as alice (group field-fte -> kagent Admin). The token mint + A2A call
# run INSIDE the cluster via `kubectl exec`, hitting the in-cluster service DNS —
# so there are no port-forwards or background jobs, and it behaves the same in a
# terminal and in a notebook cell.
#
#   ./scripts/ask.sh "Roll a 20-sided die and tell me if it is prime."
#   AS_USER=bob ./scripts/ask.sh "..."      # different Keycloak user
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

AGENT="${AGENT:-$(resolve_kagent_agent "${AGENT_PREFIX:-agentdemo}")}"
AS_USER="${AS_USER:-admin-user}"; AS_PASSWORD="${AS_PASSWORD:-password}"
[[ -n "$AGENT" ]] || die "no kagent Agent matching '${AGENT_PREFIX:-agentdemo}' — is it deployed?"
PROMPT="${*:-Roll a 20-sided die and tell me whether the result is a prime number.}"

POD="$(kc -n kagent get pods -l "app.kubernetes.io/name=$AGENT" -o name 2>/dev/null | head -1)"
[[ -n "$POD" ]] || die "no running pod for agent '$AGENT' — check: kubectl -n kagent get pods"

echo "Asking '$AGENT' as $AS_USER (OIDC) ..."
# Mint from the IN-CLUSTER Keycloak URL (the agent pod can't resolve the
# browser-facing keycloak.localtest.me issuer). KC_HOSTNAME stamps the same
# localtest.me `iss` on the token, which the controller validates.
ISSUER="${KEYCLOAK_MINT_URL:-http://keycloak.${KEYCLOAK_NS}.svc.cluster.local:8080/realms/${KEYCLOAK_REALM}}"
kc -n kagent exec -i "${POD#*/}" -- python3 - "$AGENT" "$AS_USER" "$PROMPT" "$ISSUER" "$KAGENT_CLI_CLIENT" "$AS_PASSWORD" "${ASK_TRACE:-1}" <<'PY'
import sys, json, urllib.request, urllib.parse
agent, user, prompt, issuer, client, password = sys.argv[1:7]
trace = (sys.argv[7] if len(sys.argv) > 7 else "1") != "0"
tok = json.load(urllib.request.urlopen(issuer + "/protocol/openid-connect/token",
      urllib.parse.urlencode({"grant_type":"password","client_id":client,"username":user,"password":password}).encode()))["access_token"]
body = json.dumps({"jsonrpc":"2.0","id":"1","method":"message/send","params":{"message":{
      "role":"user","parts":[{"kind":"text","text":prompt}],"messageId":"ask-1"}}}).encode()
req = urllib.request.Request("http://kagent-controller.kagent.svc.cluster.local:8083/api/a2a/kagent/%s/" % agent,
      body, {"Authorization":"Bearer "+tok, "Content-Type":"application/json"})
d = json.load(urllib.request.urlopen(req, timeout=240))
r = d.get("result", d)

# --- tool-call trace: the A2A result.history carries the agent's tool calls as
# data parts (a {name,args,id} call, then a {name,id,response} result). Pair them
# by id and print the chain, so you can watch the local -> MCP -> local hops without
# a working trace backend. Suppress with ASK_TRACE=0.
def _out(resp):
    if not isinstance(resp, dict): return resp
    sc = resp.get("structuredContent")
    if isinstance(sc, dict) and "result" in sc: return sc["result"]
    if "result" in resp: return resp["result"]
    c = resp.get("content")
    if isinstance(c, list):
        txt = " ".join(str(x.get("text","")) for x in c if isinstance(x, dict))
        return txt or json.dumps(resp)
    return json.dumps(resp)
calls, resps = [], {}
if isinstance(r, dict):
    for m in (r.get("history") or []):
        if not isinstance(m, dict): continue
        for p in m.get("parts", []):
            if isinstance(p, dict) and p.get("kind") == "data":
                data = p.get("data", {})
                if isinstance(data, dict) and "name" in data:
                    if "args" in data: calls.append(data)
                    elif "response" in data: resps[data.get("id")] = data["response"]
if calls and trace:
    print("\nTrace (tools the agent called):")
    for i, c in enumerate(calls, 1):
        args = c.get("args") or {}
        a = ", ".join("%s=%s" % (k, json.dumps(v) if isinstance(v, (list, dict)) else v)
                      for k, v in args.items()) if isinstance(args, dict) else json.dumps(args)
        print("  %d. %s(%s) -> %s" % (i, c.get("name"), a, _out(resps.get(c.get("id"), ""))))

# --- final answer (from artifacts, falling back to the result body) ---
seen=[]
def w(o):
    if isinstance(o, dict):
        if o.get("role")=="user": return
        if o.get("kind")=="text" and isinstance(o.get("text"), str):
            t=o["text"].strip()
            if t and t not in seen: seen.append(t)
        [w(v) for v in o.values()]
    elif isinstance(o, list):
        [w(v) for v in o]
w(r.get("artifacts") if isinstance(r, dict) and r.get("artifacts") else r)
print("\n" + ("\n\n".join(seen) if seen else "A2A error: " + json.dumps(d.get("error", d))[:500]))
PY
