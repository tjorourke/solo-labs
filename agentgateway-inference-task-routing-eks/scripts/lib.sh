# Shared by every script in this lab. Source it, then use kubectl, helm_, gw_up and gw_curl.
#
# Cluster selection is Part 1's: the current kubectl context by default, KUBE_CONTEXT to
# name one, or EKS_CLUSTER (default model-routing) for the cloud case. PART3_DIR points at
# the Part 3 lab, whose cluster, models, identity key and OPA manifest this part reuses.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PART1_DIR="$(cd "${PART1_DIR:-$HERE/../agentgateway-inference-model-routing-eks}" 2>/dev/null && pwd || echo "${PART1_DIR:-}")"
PART3_DIR="$(cd "${PART3_DIR:-$HERE/../agentgateway-inference-identity-routing-eks}" 2>/dev/null && pwd || echo "${PART3_DIR:-}")"
EKS_CLUSTER="${EKS_CLUSTER:-model-routing}"
AWS_REGION="${AWS_REGION:-eu-west-2}"
export EKS_CLUSTER AWS_REGION
NS=agentgateway-system
banner() { echo; echo "==> $*"; }

resolve_ctx() {
  if [ -n "${KUBE_CONTEXT:-}" ]; then CTX="$KUBE_CONTEXT"; return; fi
  local account arn found cluster_entry
  account="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
  [ -n "$account" ] && [ "$account" != "None" ] \
    || { echo "error: no AWS identity. Check AWS_PROFILE, or run aws sso login." >&2; exit 1; }
  arn="arn:aws:eks:${AWS_REGION}:${account}:cluster/${EKS_CLUSTER}"
  if command kubectl config get-contexts -o name 2>/dev/null | grep -qxF "$arn"; then CTX="$arn"; return; fi
  for cluster_entry in "$arn" "${EKS_CLUSTER}.${AWS_REGION}.eksctl.io"; do
    found="$(command kubectl config view -o \
      "jsonpath={range .contexts[?(@.context.cluster=='${cluster_entry}')]}{.name}{'\n'}{end}" 2>/dev/null | head -1)"
    if [ -n "$found" ]; then CTX="$found"; return; fi
  done
  aws eks update-kubeconfig --region "$AWS_REGION" --name "$EKS_CLUSTER" >/dev/null
  CTX="$arn"
}
resolve_ctx
kubectl() { command kubectl --context "$CTX" "$@"; }
helm_()   { helm --kube-context "$CTX" "$@"; }

# The public gateway is ClusterIP with no external address, so the scripts reach it
# through a port-forward and send the hostname its route is bound to.
GW_PORT="${GW_PORT:-18080}"
GW_HOST=model-gateway.agentgateway-system.svc.cluster.local
GW_URL="http://localhost:${GW_PORT}/v1/chat/completions"
gw_up() {
  if ! curl -s -o /dev/null -m 2 -H "Host: $GW_HOST" "http://localhost:${GW_PORT}/" 2>/dev/null; then
    kubectl -n "$NS" port-forward svc/model-gateway "${GW_PORT}:80" >/dev/null 2>&1 &
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
