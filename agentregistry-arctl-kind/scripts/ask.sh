#!/usr/bin/env bash
# ask.sh "<prompt>" — call the hosted summarizer agent through the kagent
# controller's A2A endpoint and print its reply. The enterprise controller
# validates an OIDC bearer, so we mint alice's Keycloak token first (alice is in
# group field-fte -> Admin, so she may invoke agents). kagent serves every agent
# as an A2A server at /api/a2a/<ns>/<name>/ (trailing slash matters).
#
#   ./scripts/ask.sh "summarize this: <paste text with a couple of https:// links>"
#   AS_USER=alice ./scripts/ask.sh "..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

# The registry suffixes the kagent Agent with its tag + deployment name; resolve
# the real name unless AGENT is set explicitly.
AGENT="${AGENT:-$(resolve_kagent_agent summarizer)}"; AS_USER="${AS_USER:-alice}"
[[ -n "$AGENT" ]] || die "no kagent Agent matching 'summarizer' found (is it deployed?)"
if [[ "$#" -gt 0 ]]; then PROMPT="$*"; elif [[ ! -t 0 ]]; then PROMPT="$(cat)"; fi
if [[ -z "${PROMPT:-}" ]]; then
  PROMPT="summarize this: AgentRegistry is an open catalog for AI agents, MCP servers, skills and prompts. The arctl CLI scaffolds a new artifact from a template, builds it into an OCI image, and publishes it to a registry so other people can discover and reuse it. The registry daemon exposes an API and a web UI on port 12121. A Kubernetes Runtime adapter translates a Deployment resource into kagent CRDs, which means a published agent can be hosted on Solo Enterprise for kagent with OIDC authentication enforced in front of it. Docs live at https://aregistry.ai and the source is at https://github.com/agentregistry-dev/agentregistry. The project is Apache 2 licensed."
fi
PROMPT="$(printf '%s' "$PROMPT" | tr '\n' ' ' | sed 's/  */ /g')"

step "1/2  ${AS_USER}'s Keycloak token"
kc -n "$KEYCLOAK_NS" port-forward svc/keycloak 18080:80 >/tmp/arctl-kc-pf.$$ 2>&1 & KPF=$!
for _ in $(seq 1 30); do curl -s -o /dev/null "http://localhost:18080/realms/${KEYCLOAK_REALM}/.well-known/openid-configuration" && break; sleep 1; done
TOKEN="$(curl -s -X POST "http://localhost:18080/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d "grant_type=password&client_id=${KEYCLOAK_CLIENT}&username=${AS_USER}&password=${AS_USER}" \
  | python3 -c 'import json,sys;print(json.load(sys.stdin).get("access_token",""))')"
kill $KPF 2>/dev/null || true
[[ -n "$TOKEN" ]] || die "could not mint ${AS_USER} token (is Keycloak up?)"
log "claims:"; decode_jwt "$TOKEN" | sed 's/^/    /' >&2 || true

step "2/2  Calling ${AGENT} through kagent A2A as ${AS_USER}"
kc -n kagent port-forward svc/kagent-controller 8083:8083 >/tmp/arctl-a2a-pf.$$ 2>&1 & CPF=$!
trap 'kill $CPF 2>/dev/null || true' EXIT
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
        if o.get("role")=="user": return
        if o.get("kind")=="text" and isinstance(o.get("text"),str):
            t=o["text"].strip()
            if t and t not in seen: seen.append(t)
        [w(v) for v in o.values()]
    elif isinstance(o,list): [w(v) for v in o]
r=d.get("result",d)
# message/send returns an A2A task; the final reply is in result.artifacts.
# Fall back to walking everything (minus user messages) for other shapes.
w(r.get("artifacts") if isinstance(r,dict) and r.get("artifacts") else r)
print("\n\n".join(seen) if seen else json.dumps(d)[:1500])
'
echo "" >&2
