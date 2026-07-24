#!/usr/bin/env bash
# lib.sh — shared helpers for the demo-4 (AgentRegistry) scripts on mesh1.
# Self-contained: no dependency on the source agentcore lab. Sourced by
# connect.sh, ask.sh and add-skill.sh. Reads .env.mesh1 (written by setup-mesh1.sh)
# for the sslip hostnames and the mesh1 LB IP.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"      # the agentregistry/ dir
PROJECT_ROOT="${PROJECT_ROOT:-$LAB_ROOT}"     # where `arctl init agent` scaffolds

# platform facts from the standup
set -a
[ -f "$LAB_ROOT/.env.mesh1" ] && . "$LAB_ROOT/.env.mesh1"
set +a

# cluster + namespaces (mesh1 is the single cluster for this demo)
export CTX="${CTX:-kind-mesh1}"
export AR_NS="${AR_NS:-agentregistry-system}"
export KEYCLOAK_NS="${KEYCLOAK_NS:-ar-keycloak}"
export KEYCLOAK_REALM="${KEYCLOAK_REALM:-agentregistry}"

# OIDC: the browser-facing issuer (sslip host) is what kagent + AR validate. In-cluster
# clients mint from the Service URL but KC_HOSTNAME stamps the same sslip `iss`.
export KEYCLOAK_ISSUER="${KEYCLOAK_ISSUER:-http://${KEYCLOAK_HOST}/realms/${KEYCLOAK_REALM}}"
export KEYCLOAK_MINT_URL="${KEYCLOAK_MINT_URL:-http://keycloak.${KEYCLOAK_NS}.svc.cluster.local:8080/realms/${KEYCLOAK_REALM}}"
export ARCTL_API_BASE_URL="${ARCTL_API_BASE_URL:-http://${AR_HOST}}"
export AR_CLI_CLIENT="${AR_CLI_CLIENT:-ar-cli-password}"       # arctl login (password grant)
export KAGENT_CLI_CLIENT="${KAGENT_CLI_CLIENT:-kagent-cli-password}"  # ask.sh scripted mint (aud kagent-backend)
export AS_USER="${AS_USER:-admin-user}"
export AS_PASSWORD="${AS_PASSWORD:-password}"

# local image registry the arctl scaffolds push to (kind-registry on localhost:5001)
export REG_NAME="${REG_NAME:-kind-registry}"
export REG_PORT="${REG_PORT:-5001}"

# arctl on PATH, clean output for a notebook kernel
export PATH="$HOME/.arctl/bin:$PATH"
export NO_COLOR=1 CLICOLOR=0
unset PROMPT_COMMAND
if ps -o comm= -p "$PPID" 2>/dev/null | grep -qi python \
   || stty -a 2>/dev/null | grep -Eq '(^|[[:space:]])-echo([[:space:],]|$)'; then
  export TERM=dumb
else
  : "${TERM:=dumb}"; export TERM
fi

kc(){ kubectl --context "$CTX" "$@"; }
step(){ printf '\n\033[1m▸ %s\033[0m\n' "$*" >&2; }
ok(){   printf '  \033[32m✓ %s\033[0m\n' "$*" >&2; }
warn(){ printf '  \033[33m! %s\033[0m\n' "$*" >&2; }
die(){  printf '  \033[31m✗ %s\033[0m\n' "$*" >&2; return 1; }

resolve_kagent_agent() {
  kc -n kagent get agents.kagent.dev -o name 2>/dev/null | sed 's#.*/##' | grep -i "^${1:-agentdemo}" | head -1
}

# load_secrets — source an optional secrets env (AWS_PROFILE, AWS_REGION,
# AGENT_GIT_URL) for the AWS AgentCore step. Point SECRETS_FILE at your local
# secrets before running the AgentCore scripts; nothing here is committed.
load_secrets() {
  [ -n "${SECRETS_FILE:-}" ] && [ -f "$SECRETS_FILE" ] && { set -a; . "$SECRETS_FILE"; set +a; }
  return 0
}

# arctl_token — mint a registry bearer for tools that read ARCTL_API_TOKEN
# (e.g. `arctl runtime setup`) rather than the login keychain.
arctl_token() {
  curl -s -X POST "${KEYCLOAK_ISSUER}/protocol/openid-connect/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d "grant_type=password&client_id=${AR_CLI_CLIENT}&username=${AS_USER}&password=${AS_PASSWORD}" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null
}

arctl_login() {
  local _n
  for _n in $(seq 1 60); do
    curl -sf -m2 -o /dev/null "${KEYCLOAK_ISSUER}/.well-known/openid-configuration" && break
    sleep 1
  done
  for _n in 1 2 3 4 5; do
    OIDC_ISSUER="$KEYCLOAK_ISSUER" OIDC_CLIENT_ID="$AR_CLI_CLIENT" \
    arctl user login \
      --oidc-flow password-credentials \
      --oidc-issuer-url "$KEYCLOAK_ISSUER" \
      --oidc-client-id "$AR_CLI_CLIENT" \
      --oidc-username "$AS_USER" --oidc-password "$AS_PASSWORD" >/dev/null 2>&1 \
    && return 0
    sleep 3
  done
  warn "arctl user login failed — is ${KEYCLOAK_ISSUER} reachable?"
  return 1
}
