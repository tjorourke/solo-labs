#!/usr/bin/env bash
# ask.sh <agent> "<prompt>" — talk to one of the two agents through kagent's
# OIDC-protected A2A endpoint.
#
# The token mint and the A2A call both run INSIDE the cluster via kubectl exec,
# against in-cluster service DNS, so there are no port-forwards or background
# jobs to manage.
#
#   ./scripts/ask.sh sretriage    "which pods are unhealthy in shop?"
#   ./scripts/ask.sh sreremediate "restart the checkout deployment"
#
# The timeout is deliberately long (default 900s). Asking the red agent to change
# something parks its tool call at the approval queue, and this call stays open
# until you decide at http://hitl.<LB>.sslip.io. That wait IS the demo.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

AGENT="${1:-}"
[[ -n "$AGENT" ]] || die "usage: ./scripts/ask.sh <${GREEN_AGENT}|${RED_AGENT}> \"<prompt>\""
shift
PROMPT="${*:-which pods are unhealthy in the shop namespace?}"
ASK_TIMEOUT="${ASK_TIMEOUT:-900}"

kc -n "$KAGENT_NS" get agent "$AGENT" >/dev/null 2>&1 \
  || die "no kagent Agent '$AGENT' — check: kubectl --context $CTX -n $KAGENT_NS get agent"

POD="$(kc -n "$KAGENT_NS" get pods -l "app.kubernetes.io/name=$AGENT" -o name 2>/dev/null | head -1)"
[[ -n "$POD" ]] || die "no running pod for '$AGENT' — check: kubectl --context $CTX -n $KAGENT_NS get pods"

VERDICT="$(kc -n "$KAGENT_NS" get agent "$AGENT" \
  -o jsonpath="{.metadata.labels.risk\.platform\.solo\.io/verdict}" 2>/dev/null)"
step "Asking '$AGENT' (verdict: ${VERDICT:-none}) as $AS_USER"
log "prompt: $PROMPT"
[[ "$VERDICT" == "red" ]] && log "this agent is gated — a mutating call will park until you approve it"

# Mint from the in-cluster Keycloak URL: the agent pod cannot resolve the
# browser-facing sslip issuer, but KC_HOSTNAME stamps the same `iss` on the token,
# which is what the controller validates.
ISSUER="http://keycloak.${KEYCLOAK_NS}.svc.cluster.local:8080/realms/${KEYCLOAK_REALM}"

kc -n "$KAGENT_NS" exec -i "${POD#*/}" -- python3 - \
  "$AGENT" "$AS_USER" "$PROMPT" "$ISSUER" "kagent-cli-password" "$AS_PASSWORD" \
  "$KAGENT_NS" "$ASK_TIMEOUT" <<'PY'
import sys, json, urllib.request, urllib.parse

agent, user, prompt, issuer, client, password, ns, timeout = sys.argv[1:9]

tok = json.load(urllib.request.urlopen(
    issuer + "/protocol/openid-connect/token",
    urllib.parse.urlencode({
        "grant_type": "password", "client_id": client,
        "username": user, "password": password,
    }).encode()))["access_token"]

body = json.dumps({
    "jsonrpc": "2.0", "id": "1", "method": "message/send",
    "params": {"message": {"role": "user",
                           "parts": [{"kind": "text", "text": prompt}],
                           "messageId": "ask-1"}},
}).encode()

req = urllib.request.Request(
    "http://kagent-controller.%s.svc.cluster.local:8083/api/a2a/%s/%s/" % (ns, ns, agent),
    body, {"Authorization": "Bearer " + tok, "Content-Type": "application/json"})

try:
    d = json.load(urllib.request.urlopen(req, timeout=float(timeout)))
except Exception as e:
    print("\nrequest failed: %s" % e)
    print("If this was the red agent, the approval may simply not have arrived in time.")
    sys.exit(1)

r = d.get("result", d)


def _out(resp):
    """Flatten an MCP tool response down to something readable."""
    if not isinstance(resp, dict):
        return resp
    sc = resp.get("structuredContent")
    if isinstance(sc, dict) and "result" in sc:
        return sc["result"]
    if "result" in resp:
        return resp["result"]
    c = resp.get("content")
    if isinstance(c, list):
        txt = " ".join(str(x.get("text", "")) for x in c if isinstance(x, dict))
        return txt or json.dumps(resp)
    return json.dumps(resp)


# The A2A history carries the agent's tool calls as data parts: a {name,args,id}
# call followed by a {name,id,response} result. Pair them by id so the tool chain
# is visible without needing a trace backend.
calls, resps = [], {}
if isinstance(r, dict):
    for m in (r.get("history") or []):
        if not isinstance(m, dict):
            continue
        for p in m.get("parts", []):
            if isinstance(p, dict) and p.get("kind") == "data":
                data = p.get("data", {})
                if isinstance(data, dict) and "name" in data:
                    if "args" in data:
                        calls.append(data)
                    elif "response" in data:
                        resps[data.get("id")] = data["response"]

if calls:
    print("\nTools the agent called:")
    for i, c in enumerate(calls, 1):
        args = c.get("args") or {}
        a = ", ".join("%s=%s" % (k, json.dumps(v) if isinstance(v, (list, dict)) else v)
                      for k, v in args.items()) if isinstance(args, dict) else json.dumps(args)
        print("  %d. %s(%s)\n       -> %s" % (i, c.get("name"), a, _out(resps.get(c.get("id"), "(no result)"))))

# Final assistant text.
texts = []
if isinstance(r, dict):
    for m in (r.get("history") or []):
        if isinstance(m, dict) and m.get("role") == "agent":
            for p in m.get("parts", []):
                if isinstance(p, dict) and p.get("kind") == "text" and p.get("text"):
                    texts.append(p["text"])
    art = r.get("artifacts") or []
    for x in art:
        for p in (x.get("parts") or []):
            if isinstance(p, dict) and p.get("kind") == "text" and p.get("text"):
                texts.append(p["text"])

print("\nAnswer:")
print(texts[-1].strip() if texts else json.dumps(r)[:2000])
PY
