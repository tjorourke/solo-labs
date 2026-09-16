# Shared by every script in this lab. Source it, then use kubectl, helm_, gw_up and gw_curl.
#
# Cluster selection: the current kubectl context, or KUBE_CONTEXT to name one. Nothing here
# is tied to a cloud. PART3_DIR points at the Part 3 lab, whose identity key and OPA manifest
# this part reuses when it is next door.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PART3_DIR="$(cd "${PART3_DIR:-$HERE/../agentgateway-inference-identity-routing-eks}" 2>/dev/null && pwd || echo "${PART3_DIR:-}")"
NS=agentgateway-system
banner() { echo; echo "==> $*"; }
CTX="${KUBE_CONTEXT:-$(command kubectl config current-context 2>/dev/null || true)}"
[ -n "$CTX" ] || { echo "error: no kubectl context. Set KUBE_CONTEXT or point kubectl at your cluster." >&2; exit 1; }
kubectl() { command kubectl --context "$CTX" "$@"; }
helm_()   { helm --kube-context "$CTX" "$@"; }

# The public gateway is ClusterIP with no external address, so the scripts reach it
# through a port-forward and send the hostname its route is bound to.
GW_PORT="${GW_PORT:-18080}"
# The tests enter where a client enters: the intake hop, which normalises the model name
# and the tool shapes and lifts an editor's question out of its envelope. Set GW_SVC to
# model-gateway to test the classify hop on its own.
GW_SVC="${GW_SVC:-intake-gateway}"
GW_HOST="${GW_HOST:-intake-gateway.agentgateway-system.svc.cluster.local}"
GW_URL="http://localhost:${GW_PORT}/v1/chat/completions"
# A port-forward is a process that can die quietly, and a dead one makes every request
# look like a gateway failure. This starts one if nothing answers, waits for it to carry a
# request, and is safe to call again before any request.
gw_up() {
  local i
  for i in $(seq 1 3); do
    curl -s -o /dev/null -m 2 -H "Host: $GW_HOST" "http://localhost:${GW_PORT}/" 2>/dev/null && return 0
    [ -n "${GW_PF:-}" ] && kill "$GW_PF" 2>/dev/null
    kubectl -n "$NS" port-forward "svc/$GW_SVC" "${GW_PORT}:80" >/dev/null 2>&1 &
    GW_PF=$!
    # No EXIT trap to tidy this up, deliberately. An EXIT trap is inherited by every
    # subshell, and this file is full of command substitutions like $(pool), so the trap
    # fired every time a header was read and killed the port-forward the next request
    # needed. The request after that then reported a transport failure as though the
    # gateway had refused it. A forward left running is harmless: gw_up reuses a healthy
    # one, and `pkill -f "port-forward svc/$GW_SVC"` clears it.
    local _
    for _ in $(seq 1 30); do
      curl -s -o /dev/null -m 2 -H "Host: $GW_HOST" "http://localhost:${GW_PORT}/" 2>/dev/null && return 0
      sleep 0.5
    done
  done
  echo "gw_up: nothing answering on localhost:${GW_PORT} for svc/$GW_SVC" >&2
  return 1
}

# gw_curl <token|-> <json body> [extra curl args...]
# Writes the response headers to $HDR and the body to $BODY, and sets STATUS.
HDR="${TMPDIR:-/tmp}/tr-hdr.$$"; BODY="${TMPDIR:-/tmp}/tr-body.$$"
gw_curl() {
  local tok="$1" body="$2"; shift 2
  local auth=(); [ "$tok" != "-" ] && auth=(-H "Authorization: Bearer $tok")
  # Clear both files first. A port-forward that has died mid-run makes curl write nothing,
  # and the previous request's headers would then be read as this request's answer: a
  # refusal that never happened, or a pool the gateway never chose.
  : > "$HDR"; : > "$BODY"
  curl -s -m 180 -D "$HDR" -o "$BODY" -H "Host: $GW_HOST" -H 'content-type: application/json' \
    ${auth[@]+"${auth[@]}"} "$@" -d "$body" "$GW_URL" || true
  STATUS="$(head -1 "$HDR" 2>/dev/null | awk '{print $2}')"
  if [ -z "$STATUS" ]; then
    # kubectl port-forward drops connections under load. Re-establish it and try once more,
    # rather than reporting a transport failure as a gateway decision.
    [ -n "${GW_PF:-}" ] && kill "$GW_PF" 2>/dev/null
    unset GW_PF
    gw_up
    : > "$HDR"; : > "$BODY"
    curl -s -m 180 -D "$HDR" -o "$BODY" -H "Host: $GW_HOST" -H 'content-type: application/json' \
      ${auth[@]+"${auth[@]}"} "$@" -d "$body" "$GW_URL" || true
    STATUS="$(head -1 "$HDR" 2>/dev/null | awk '{print $2}')"
  fi
  STATUS="${STATUS:-000}"
}
# Response headers. x-model-pool, x-model-class and x-routing-reason are OPA's decision,
# echoed back to the client by the Rego. x-vsr-selected-model is the router's task label.
hdr()    { { grep -i "^$1:" "$HDR" || true; } | head -1 | cut -d' ' -f2- | tr -d '\r'; }
pool()   { hdr x-model-pool; }
mclass() { hdr x-model-class; }
reason() { hdr x-routing-reason; }
task()   { hdr x-vsr-selected-model; }
# The model named in the response body: the server's own statement of which model
# answered. For an error, the error message.
resp_model() {
  python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get("model") or "ERR " + (d.get("error", {}).get("message") if isinstance(d.get("error"), dict) else json.dumps(d))[:70])
except Exception:
    print("ERR " + open(sys.argv[1]).read()[:70].strip())' "$BODY"
}
load_tokens() {
  [ -f "$HERE/identity/tokens.env" ] || { echo "error: no identity/tokens.env. Run ./scripts/01-identity.sh" >&2; exit 1; }
  . "$HERE/identity/tokens.env"
}
# chat <prompt> [model] -> a chat-completions body. The model is auto: the gateway chooses.
chat() {
  python3 -c 'import json,sys; print(json.dumps({"model": sys.argv[2], "max_tokens": 24, "messages": [{"role": "user", "content": sys.argv[1]}]}))' "$1" "${2:-auto}"
}
