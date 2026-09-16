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
gw_up() {
  if ! curl -s -o /dev/null -m 2 -H "Host: $GW_HOST" "http://localhost:${GW_PORT}/" 2>/dev/null; then
    kubectl -n "$NS" port-forward "svc/$GW_SVC" "${GW_PORT}:80" >/dev/null 2>&1 &
    GW_PF=$!
    trap 'kill ${GW_PF:-0} 2>/dev/null || true' EXIT
    for _ in $(seq 1 30); do
      curl -s -o /dev/null -m 2 -H "Host: $GW_HOST" "http://localhost:${GW_PORT}/" 2>/dev/null && break
      sleep 0.5
    done
  fi
}

# gw_curl <token|-> <json body> [extra curl args...]
# Writes the response headers to $HDR and the body to $BODY, and sets STATUS.
HDR="${TMPDIR:-/tmp}/tr-hdr.$$"; BODY="${TMPDIR:-/tmp}/tr-body.$$"
gw_curl() {
  local tok="$1" body="$2"; shift 2
  local auth=(); [ "$tok" != "-" ] && auth=(-H "Authorization: Bearer $tok")
  curl -s -m 180 -D "$HDR" -o "$BODY" -H "Host: $GW_HOST" -H 'content-type: application/json' \
    ${auth[@]+"${auth[@]}"} "$@" -d "$body" "$GW_URL" || true
  STATUS="$(head -1 "$HDR" | awk '{print $2}')"
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
