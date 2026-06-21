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
kc -n kagent exec -i "${POD#*/}" -- python3 - "$AGENT" "$AS_USER" "$PROMPT" "$ISSUER" "$KAGENT_CLI_CLIENT" "$AS_PASSWORD" <<'PY'
import sys, json, urllib.request, urllib.parse
agent, user, prompt, issuer, client, password = sys.argv[1:7]
tok = json.load(urllib.request.urlopen(issuer + "/protocol/openid-connect/token",
      urllib.parse.urlencode({"grant_type":"password","client_id":client,"username":user,"password":password}).encode()))["access_token"]
body = json.dumps({"jsonrpc":"2.0","id":"1","method":"message/send","params":{"message":{
      "role":"user","parts":[{"kind":"text","text":prompt}],"messageId":"ask-1"}}}).encode()
req = urllib.request.Request("http://kagent-controller.kagent.svc.cluster.local:8083/api/a2a/kagent/%s/" % agent,
      body, {"Authorization":"Bearer "+tok, "Content-Type":"application/json"})
d = json.load(urllib.request.urlopen(req, timeout=240))
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
r = d.get("result", d)
w(r.get("artifacts") if isinstance(r, dict) and r.get("artifacts") else r)
print("\n" + ("\n\n".join(seen) if seen else "A2A error: " + json.dumps(d.get("error", d))[:500]))
PY
