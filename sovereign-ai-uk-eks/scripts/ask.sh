#!/usr/bin/env bash
# Talk to Mistral through agentgateway. Streams the answer as it generates.
#
#   ./scripts/ask.sh "your question here"
#   ./scripts/ask.sh                       # interactive: type questions, blank line quits
#   MAXTOK=400 ./scripts/ask.sh "..."      # longer answer (default 200)
#   RAW=1 ./scripts/ask.sh "..."           # print the raw JSON/SSE, no formatting
#
# The request goes to the PUBLIC gateway listener, authenticated with a Keycloak token,
# never to vLLM directly. That is the whole point: the only way to the model is through
# the one governed door.
set -euo pipefail

export AWS_PROFILE="${SOVEREIGN_AWS_PROFILE:?set SOVEREIGN_AWS_PROFILE to the sandbox SSO profile}"
REGION=eu-west-2
CLUSTER=uk-sovereign-ai
GW_NS=agentgateway-system
MODEL="${MODEL:-mistral-small-3.2-24b}"
MAXTOK="${MAXTOK:-200}"
USER_NAME="${USER_NAME:-alice}"   # which Keycloak user to authenticate as

ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
[ -n "$ACCOUNT" ] && [ "$ACCOUNT" != "None" ] || { echo "error: no AWS identity; check SOVEREIGN_AWS_PROFILE" >&2; exit 1; }
CTX="arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${CLUSTER}"
LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

HOST="$(kubectl --context "$CTX" -n "$GW_NS" get svc sovereign-gateway \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)"
[ -n "$HOST" ] || { echo "error: gateway has no LoadBalancer hostname yet" >&2; exit 1; }
# HTTPS, always. The gateway terminates TLS and redirects plaintext, so http would just
# 301. The edge CA is private, so curl needs to trust it; tls.sh writes it out.
URL="https://${HOST}/v1/chat/completions"
CA="${GW_CACERT_DIR:-$HOME/.solo-sovereign}/gateway-ca.crt"
[ -f "$CA" ] || SOVEREIGN_AWS_PROFILE="$AWS_PROFILE" "$LAB_ROOT/scripts/tls.sh" cacert >/dev/null 2>&1 || true
CACERT=(); [ -f "$CA" ] && CACERT=(--cacert "$CA")

# A short system prompt so the model can speak to where it runs. Base Mistral has no idea
# it is in London, so without this it correctly says it has no location. The sovereignty
# is a property of the deployment, not something the weights know; this just lets the demo
# say it out loud. Override or blank it with SYSTEM=.
SYSTEM="${SYSTEM:-You are an assistant hosted on sovereign UK infrastructure: an open-weight model served by vLLM on a GPU in AWS eu-west-2 (London), reached only through agentgateway. You may state that you run in the UK and that requests stay in-region.}"

# A Keycloak-issued token for the JWT policy on the gateway. keycloak.sh mints it; if the
# JWT policy is not applied yet the call still works, this just future-proofs it.
TOKEN="$(SOVEREIGN_AWS_PROFILE="$AWS_PROFILE" "$LAB_ROOT/scripts/keycloak.sh" token "$USER_NAME" 2>/dev/null || true)"
AUTH=(); [ -n "$TOKEN" ] && AUTH=(-H "Authorization: Bearer $TOKEN")

ask() {
  local q="$1"
  local body
  body=$(SYS="$SYSTEM" Q="$q" MODEL="$MODEL" MAXTOK="$MAXTOK" python3 -c '
import json, os
msgs = []
if os.environ.get("SYS"): msgs.append({"role":"system","content":os.environ["SYS"]})
msgs.append({"role":"user","content":os.environ["Q"]})
print(json.dumps({"model":os.environ["MODEL"],"stream":True,"max_tokens":int(os.environ["MAXTOK"]),"messages":msgs}))')
  if [ "${RAW:-0}" = "1" ]; then
    curl -sN "${CACERT[@]}" --max-time 120 "${AUTH[@]}" -H 'content-type: application/json' -d "$body" "$URL"
    echo; return
  fi
  # SSE: each line is "data: {json}". Pull the streamed content deltas out and print them
  # as they arrive, so a long answer appears token by token rather than after a silence.
  curl -sN "${CACERT[@]}" --max-time 120 "${AUTH[@]}" -H 'content-type: application/json' -d "$body" "$URL" \
  | python3 -u -c '
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("data:"): continue
    data = line[5:].strip()
    if data == "[DONE]": break
    try:
        d = json.loads(data)
        delta = d["choices"][0].get("delta", {}).get("content", "")
        if delta: sys.stdout.write(delta); sys.stdout.flush()
    except Exception:
        pass
print()
'
}

if [ "$#" -gt 0 ]; then
  ask "$*"
else
  echo "Mistral, via agentgateway in London. Blank line to quit."
  echo "gateway: $URL"
  while true; do
    printf '\n\033[36myou ›\033[0m '
    IFS= read -r q || break
    [ -z "$q" ] && break
    printf '\033[32mmistral ›\033[0m '
    ask "$q"
  done
fi
