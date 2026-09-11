#!/usr/bin/env bash
# lib.sh: shared helpers for the agent-authoring series (Parts 1 to 5).
#
# Every lab in the series sources this file, so the cluster it targets, the namespace,
# the controller endpoint and the token are decided in one place. The series runs on an
# existing cluster; nothing here creates one.
#
#   CTX             kubectl context to use (default: the current context)
#   KAGENT_TOKEN    bearer token for the kagent controller API. Leave unset to have one
#                   minted from Keycloak (see mint_token), or when the controller has no
#                   authentication.
set -Eeuo pipefail

__color() { [[ -t 2 ]] && command -v tput >/dev/null 2>&1; }
if __color; then
  __dim(){ tput dim; printf '%s' "$*"; tput sgr0; }; __ok(){ tput setaf 2; printf '✓ '; tput sgr0; printf '%s' "$*"; }
  __warn(){ tput setaf 3; printf '! '; tput sgr0; printf '%s' "$*"; }; __err(){ tput setaf 1; printf 'ERROR: '; tput sgr0; printf '%s' "$*"; }
  __step(){ tput bold; printf '%s' "$*"; tput sgr0; }
else
  __dim(){ printf '%s' "$*"; }; __ok(){ printf '✓ %s' "$*"; }; __warn(){ printf '! %s' "$*"; }; __err(){ printf 'ERROR: %s' "$*"; }; __step(){ printf '%s' "$*"; }
fi
log(){ { __dim "  $*"; printf '\n'; } >&2; }
ok(){ { __ok "$*"; printf '\n'; } >&2; }
warn(){ { __warn "$*"; printf '\n'; } >&2; }
die(){ { __err "$*"; printf '\n'; } >&2; exit 1; }
step(){ printf '\n' >&2; { __step "══> $*"; printf '\n'; } >&2; }
require(){ command -v "$1" >/dev/null 2>&1 || die "$1 not found. Install it first."; }

export CTX="${CTX:-$(kubectl config current-context 2>/dev/null || true)}"
[[ -n "$CTX" ]] || die "no kubectl context. Set CTX=<context> or select one with kubectl config use-context."
export NS="${NS:-kagent}"
export SRE_NS="${SRE_NS:-sre-lab}"

# The directory holding all five labs, so a later part can reach Part 1's manifests.
SERIES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SERIES_ROOT
export PART1="$SERIES_ROOT/agent-authoring-contract-kind"

kc(){ kubectl --context "$CTX" "$@"; }

# The mesh trust domain, read from istiod's configuration. ztunnel matches authorization
# principals literally, so a policy has to carry the real value, not cluster.local.
trust_domain() {
  local td
  td="$(kc -n istio-system get cm istio -o jsonpath='{.data.mesh}' 2>/dev/null | sed -n 's/^trustDomain: *//p' | head -1)"
  echo "${td:-cluster.local}"
}

# ── the kagent controller ─────────────────────────────────────────────────────
# Reached through a port-forward on 18083. controller_pf starts one if none is running
# and stops it when the calling script exits.
export CONTROLLER_PORT="${CONTROLLER_PORT:-18083}"
export CONTROLLER_URL="http://127.0.0.1:${CONTROLLER_PORT}"
# Port-forwards are started as plain kubectl processes, not through the kc function:
# a backgrounded function runs in a subshell, and killing the subshell leaves the
# kubectl child alive on the port for the next script to talk to by mistake.
__pf_pids=()
__pf_cleanup() { local p; for p in "${__pf_pids[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done; }
trap __pf_cleanup EXIT
__start_pf() {
  local target="$1" local_port="$2" remote_port="$3" probe="$4"
  # Anything already forwarding this local port is stale from an earlier run.
  pkill -f "port-forward .* ${local_port}:${remote_port}" 2>/dev/null || true
  kubectl --context "$CTX" -n "$NS" port-forward "$target" "${local_port}:${remote_port}" >/dev/null 2>&1 &
  __pf_pids+=("$!")
  local i; for i in $(seq 1 40); do
    curl -s -m 1 -o /dev/null "$probe" 2>/dev/null && return 0; sleep 0.5
  done
  die "could not port-forward to $target in $NS on port $local_port"
}
controller_pf() {
  curl -s -m 2 -o /dev/null "$CONTROLLER_URL/health" 2>/dev/null && return 0
  __start_pf svc/kagent-controller "$CONTROLLER_PORT" 8083 "$CONTROLLER_URL/health"
}

# A port-forward straight to an agent's Service on 18080, for talking to the agent
# itself rather than through the controller.
export AGENT_PORT="${AGENT_PORT:-18080}"
export AGENT_URL="http://127.0.0.1:${AGENT_PORT}"
agent_pf() {
  __start_pf "svc/$1" "$AGENT_PORT" 8080 "$AGENT_URL/.well-known/agent-card.json"
}

# ── the token ─────────────────────────────────────────────────────────────────
# Solo Enterprise for kagent protects the controller API with OIDC. mint_token gets a
# password-grant token from Keycloak. The defaults match a cluster set up with the
# vision-demo scripts (realm agentregistry, client kagent-cli-password); override any of
# them, or set KAGENT_TOKEN and skip the mint. On a controller with no OIDC the token is
# simply not sent.
export KEYCLOAK_REALM="${KEYCLOAK_REALM:-agentregistry}"
export KEYCLOAK_CLIENT="${KEYCLOAK_CLIENT:-kagent-cli-password}"
export AS_USER="${AS_USER:-admin-user}"
export AS_PASSWORD="${AS_PASSWORD:-password}"
keycloak_url() {
  if [[ -n "${KEYCLOAK_URL:-}" ]]; then echo "$KEYCLOAK_URL"; return; fi
  local lb
  lb="$(kc -n agentgateway-system get gateway ar-ingress -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
  if [[ -n "$lb" ]]; then echo "http://keycloak.${lb}.sslip.io"; fi
}
mint_token() {
  if [[ -n "${KAGENT_TOKEN:-}" ]]; then echo "$KAGENT_TOKEN"; return; fi
  local url; url="$(keycloak_url)"
  [[ -n "$url" ]] || { echo ""; return; }
  curl -s -m 20 "$url/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token" \
    -d grant_type=password -d "client_id=${KEYCLOAK_CLIENT}" \
    -d "username=${AS_USER}" -d "password=${AS_PASSWORD}" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin).get("access_token",""))'
}
# Sets TOKEN once per script. Minted when a Keycloak is known (KEYCLOAK_URL, or the one
# behind the ar-ingress gateway); empty otherwise, for a controller with no OIDC.
TOKEN=""; TOKEN_SET=""
token() {
  if [[ -z "$TOKEN_SET" ]]; then TOKEN="$(mint_token)"; TOKEN_SET=1; fi
  echo "$TOKEN"
}
# curl against the controller with the token (if any) already attached.
ccurl() {
  local t; t="$(token)"
  if [[ -n "$t" ]]; then curl -s -H "Authorization: Bearer $t" "$@"; else curl -s "$@"; fi
}

# ── waiting ───────────────────────────────────────────────────────────────────
wait_agent_ready() {
  local name="$1" timeout="${2:-300}" end=$(( $(date +%s) + ${2:-300} ))
  until [[ "$(kc -n "$NS" get agent "$name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == "True" ]]; do
    [[ $(date +%s) -ge $end ]] && { kc -n "$NS" get agent "$name" -o yaml | sed -n '/^status:/,$p' >&2; die "agent $name not Ready in ${timeout}s"; }
    sleep 5
  done
}
wait_gateway_programmed() {
  local name="$1" end=$(( $(date +%s) + 240 ))
  until [[ "$(kc -n "$NS" get gateway "$name" -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)" == "True" ]]; do
    [[ $(date +%s) -ge $end ]] && die "gateway $name not Programmed in 240s"; sleep 3
  done
  # The data-plane pod appears a few seconds after Programmed.
  until kc -n "$NS" get pod -l "gateway.networking.k8s.io/gateway-name=$name" -o name 2>/dev/null | grep -q pod; do
    [[ $(date +%s) -ge $end ]] && die "no pod for gateway $name"; sleep 2
  done
  kc -n "$NS" wait --for=condition=Ready pod -l "gateway.networking.k8s.io/gateway-name=$name" --timeout=120s >/dev/null
}

# ── sessions and tasks ────────────────────────────────────────────────────────
# The UI lists a conversation from a stored session and its tasks. open_session creates
# the session under the token's user; ask.sh sends the turn with that session as its
# contextId, so the same conversation appears in the UI.
open_session() {
  local agent="$1" title="${2:-$1}"
  ccurl -m 20 -X POST "$CONTROLLER_URL/api/sessions" -H 'Content-Type: application/json' \
    -d "{\"agent_ref\":\"${NS}/${agent}\",\"name\":\"${title}\"}" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("data",d).get("id",""))'
}
task_count() {
  local session="$1"
  ccurl -m 20 "$CONTROLLER_URL/api/sessions/${session}/tasks" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); t=d.get("data",d); t=t.get("tasks",t) if isinstance(t,dict) else t; print(len(t or []))'
}
