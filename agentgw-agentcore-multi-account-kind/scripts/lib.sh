#!/usr/bin/env bash
# lib.sh — shared helpers for agentgw-agentcore-multi-account-kind.
#
# Story: ONE enterprise agentgateway on kind fronts AWS Bedrock AgentCore
# runtimes in TWO AWS accounts (different regions), one backend per runtime,
# each backend doing sts:AssumeRole into that account's invoke role before
# signing the invoke. AgentRegistry Enterprise runs in-cluster and does the
# deployments; its Runtimes carry NO gatewayRef, so the registry never writes
# gateway config or gateway IAM — that is the point of the lab.

set -Eeuo pipefail

__versions_env="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/versions.env"
[ -f "$__versions_env" ] && . "$__versions_env"

# Pinned: v2026.8.0 was the first chart line to ship
# spec.policies.auth.aws.assumeRole (+ sessionNameExpression) and
# spec.aws.agentCore on EnterpriseAgentgatewayBackend, and spec.env on
# EnterpriseAgentgatewayParameters, but its control plane could not translate
# spec.aws on the Enterprise kind (fixed in v2026.8.1). v2026.8.2 verified
# 2026-09-02 with the Enterprise kind end to end. Older charts fail schema
# validation; v2026.8.0 needs the OSS AgentgatewayBackend kind instead.
export AGW_VERSION="${AGW_VERSION:-v2026.8.2}"
export AGW_REGISTRY="${AGW_REGISTRY:-oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts}"
export AGW_CHART="${AGW_CHART:-${AGW_REGISTRY}/enterprise-agentgateway}"
export AGW_CRDS_CHART="${AGW_CRDS_CHART:-${AGW_REGISTRY}/enterprise-agentgateway-crds}"

__has_color() { [[ -t 2 ]] && [[ -n "${TERM:-}" && "${TERM:-}" != dumb ]] && command -v tput >/dev/null 2>&1; }
if __has_color; then
  __dim(){ tput dim;printf '%s' "$*";tput sgr0;}; __ok(){ tput setaf 2;printf '✓ ';tput sgr0;printf '%s' "$*";}
  __warn(){ tput setaf 3;printf '! ';tput sgr0;printf '%s' "$*";}; __err(){ tput setaf 1;printf 'ERROR: ';tput sgr0;printf '%s' "$*";}
  __step(){ tput bold;printf '%s' "$*";tput sgr0;}
else
  __dim(){ printf '%s' "$*";}; __ok(){ printf '✓ %s' "$*";}; __warn(){ printf '! %s' "$*";}; __err(){ printf 'ERROR: %s' "$*";}; __step(){ printf '%s' "$*";}
fi
log(){ { __dim "  $*";printf '\n';} >&2; }
ok(){ { __ok "$*";printf '\n';} >&2; }
warn(){ { __warn "$*";printf '\n';} >&2; }
die(){ { __err "$*";printf '\n';} >&2; exit 1; }
step(){ printf '\n' >&2; { __step "══> $*";printf '\n';} >&2; }
require(){ command -v "$1" >/dev/null 2>&1 || die "$1 not found — install it first"; }

# ── arctl / AgentRegistry (in-cluster) ────────────────────────────────────────
# AR 2026.8.0: first release with Kubernetes-platform registry Gateways (needed
# by 51-mismatch-demo.sh); requires a licence and config.enabledRuntimes. The
# arctl verbs this lab uses (user login, apply, get, delete, init) were
# validated with arctl v2026.6.1 against the 2026.8.0 server.
export ARCTL_VERSION="${ARCTL_VERSION:-v2026.6.1}"
export ARCTL_INSTALL_URL="${ARCTL_INSTALL_URL:-https://storage.googleapis.com/agentregistry-enterprise/install.sh}"
export AR_NS="${AR_NS:-agentregistry-system}"
export AR_VERSION="${AR_VERSION:-2026.8.0}"
export AR_CHART="${AR_CHART:-oci://us-docker.pkg.dev/solo-public/agentregistry-enterprise/helm/agentregistry-enterprise}"
export AR_SERVER_SVC="${AR_SERVER_SVC:-agentregistry-enterprise-server}"
export AR_SERVER_PORT="${AR_SERVER_PORT:-12121}"
export AR_TELEMETRY_ENDPOINT="${AR_TELEMETRY_ENDPOINT:-http://agentregistry-enterprise-telemetry-collector.${AR_NS}.svc.cluster.local:4318}"

# ── cluster ──────────────────────────────────────────────────────────────────
export PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export CLUSTER_NAME="${CLUSTER_NAME:-agw-multi-account}"
export CTX="kind-${CLUSTER_NAME}"
export GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.4.0}"

# ── Keycloak (OIDC issuer for AgentRegistry AND the gateway's JWT policy) ────
export KEYCLOAK_NS="${KEYCLOAK_NS:-keycloak}"
export KEYCLOAK_REALM="${KEYCLOAK_REALM:-agentregistry}"
export KEYCLOAK_HOST="${KEYCLOAK_HOST:-keycloak.localtest.me}"
export KEYCLOAK_ISSUER="${KEYCLOAK_ISSUER:-http://${KEYCLOAK_HOST}/realms/${KEYCLOAK_REALM}}"
export AR_CLI_CLIENT="${AR_CLI_CLIENT:-ar-cli-password}"
export AR_UI_CLIENT="${AR_UI_CLIENT:-ar-ui}"
export AR_BACKEND_CLIENT="${AR_BACKEND_CLIENT:-ar-backend}"
export AS_USER="${AS_USER:-admin-user}"
export AS_PASSWORD="${AS_PASSWORD:-password}"
export RBAC_SUPERUSER_ROLE="${RBAC_SUPERUSER_ROLE:-admins}"

# ── the single gateway ───────────────────────────────────────────────────────
export GW_NS="${GW_NS:-agentgateway-system}"
export GW_NAME="${GW_NAME:-agentgateway-proxy}"
export GW_HTTP_NODEPORT="${GW_HTTP_NODEPORT:-30080}"
export AR_HOST="${AR_HOST:-agentregistry.localtest.me}"
export AGENTS_HOST="${AGENTS_HOST:-agents.localtest.me}"
export ARCTL_API_BASE_URL="${ARCTL_API_BASE_URL:-http://${AR_HOST}}"
export GAR_HOST="${GAR_HOST:-us-docker.pkg.dev}"

# ── secrets ──────────────────────────────────────────────────────────────────
# SOLO_LICENSE_KEY: enterprise agentgateway. No ANTHROPIC_API_KEY: the agents
# run on Bedrock under AgentCore execution roles. AWS side comes from
# deploy/.env.tofu (written by scripts/10-tofu.sh) — static keys for the two
# tofu-created IAM users, plus role ARNs and external IDs.
load_secrets() {
  local lab_root; lab_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  if [[ -f "$lab_root/deploy/.env.local" ]]; then set -a; source "$lab_root/deploy/.env.local"; set +a; fi
  if [[ -n "${SECRETS_FILE:-}" ]]; then
    [[ -f "$SECRETS_FILE" ]] || die "SECRETS_FILE='$SECRETS_FILE' does not exist"
    set -a; source "$SECRETS_FILE"; set +a
  fi
  export AGENTGATEWAY_LICENSE_KEY="${AGENTGATEWAY_LICENSE_KEY:-${SOLO_LICENSE_KEY:-}}"
}
require_secrets() {
  load_secrets
  [[ -n "${AGENTGATEWAY_LICENSE_KEY:-}" ]] || die "SOLO_LICENSE_KEY (or AGENTGATEWAY_LICENSE_KEY) not set"
}
load_tofu_env() {
  local lab_root; lab_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  [[ -f "$lab_root/deploy/.env.tofu" ]] || die "deploy/.env.tofu missing — run ./scripts/10-tofu.sh first"
  set -a; source "$lab_root/deploy/.env.tofu"; set +a
  [[ -f "$lab_root/deploy/.env.runtimes" ]] && { set -a; source "$lab_root/deploy/.env.runtimes"; set +a; }
  true
}

kc(){ kubectl --context "$CTX" "$@"; }
check_docker(){ docker info >/dev/null 2>&1 || die "docker daemon not reachable"; }

decode_jwt() {
  local t="${1:-$(cat)}"
  printf '%s' "$t" | cut -d. -f2 | tr '_-' '/+' | { cat; printf '=='; } | base64 -d 2>/dev/null | python3 -m json.tool 2>/dev/null
}

wait_deploy() {
  local ns="$1" name="$2" timeout="${3:-300s}"; local end=$(( $(date +%s) + 240 ))
  until kc -n "$ns" get deployment "$name" >/dev/null 2>&1; do
    [[ $(date +%s) -ge $end ]] && { warn "deployment $ns/$name not created in 4m"; return 1; }; sleep 3
  done
  kc -n "$ns" wait --for=condition=Available deployment/"$name" --timeout="$timeout" >/dev/null
}

helm_install_with_progress() {
  local release="$1" chart="$2" namespace="$3"; shift 3
  helm --kube-context "$CTX" upgrade --install "$release" "$chart" --namespace "$namespace" --create-namespace "$@" >/dev/null &
  local pid=$!; local start; start=$(date +%s)
  while kill -0 "$pid" 2>/dev/null; do
    sleep 15; kill -0 "$pid" 2>/dev/null || break
    local e=$(( $(date +%s) - start )); local p; p=$(kc -n "$namespace" get pods --no-headers 2>/dev/null | awk '{printf "%s[%s] ",$1,$2}')
    [[ -n "$p" ]] && log "[+${e}s] pods: ${p}" || log "[+${e}s] pulling images / creating pods..."
  done
  wait "$pid"
}

ensure_gar_auth() {
  local host="${1:-$GAR_HOST}"
  command -v gcloud >/dev/null 2>&1 || die "gcloud required for the Solo enterprise charts ($host)"
  if ! gcloud auth print-access-token >/dev/null 2>&1; then
    [[ -t 0 ]] || die "gcloud not authenticated and no TTY. Run: gcloud auth login"
    gcloud auth login || die "gcloud auth login failed"
  fi
  gcloud auth print-access-token | helm registry login -u oauth2accesstoken --password-stdin "$host" >/dev/null \
    || die "helm registry login failed for $host"
}

bridge_keycloak_hostalias() {
  local dep="$1" ns="$2" host="$KEYCLOAK_HOST" ip
  ip="$(kc -n "$KEYCLOAK_NS" get svc keycloak -o jsonpath='{.spec.clusterIP}' 2>/dev/null)"
  [[ -n "$ip" ]] || { warn "keycloak ClusterIP not found; skipping hostAlias on $ns/$dep"; return 0; }
  kc -n "$ns" patch deploy "$dep" --type=json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/hostAliases\",\"value\":[{\"ip\":\"$ip\",\"hostnames\":[\"$host\"]}]}]" >/dev/null 2>&1 \
  || kc -n "$ns" patch deploy "$dep" --type=json \
    -p "[{\"op\":\"add\",\"path\":\"/spec/template/spec/hostAliases\",\"value\":[{\"ip\":\"$ip\",\"hostnames\":[\"$host\"]}]}]" >/dev/null 2>&1 || true
}

keycloak_client_secret() {
  local client="$1" pf admtok cid secret
  kc -n "$KEYCLOAK_NS" port-forward svc/keycloak 18099:8080 >/dev/null 2>&1 & pf=$!
  for _ in $(seq 1 30); do curl -sf -m2 "http://localhost:18099/realms/master/.well-known/openid-configuration" >/dev/null 2>&1 && break; sleep 1; done
  admtok="$(curl -s -X POST "http://localhost:18099/realms/master/protocol/openid-connect/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d 'grant_type=password&client_id=admin-cli&username=admin&password=admin' 2>/dev/null | jq -r '.access_token // empty')"
  cid="$(curl -s -H "Authorization: Bearer $admtok" \
    "http://localhost:18099/admin/realms/${KEYCLOAK_REALM}/clients?clientId=${client}" 2>/dev/null | jq -r '.[0].id // empty')"
  secret="$(curl -s -H "Authorization: Bearer $admtok" \
    "http://localhost:18099/admin/realms/${KEYCLOAK_REALM}/clients/${cid}/client-secret" 2>/dev/null | jq -r '.value // empty')"
  kill "$pf" 2>/dev/null || true
  printf '%s' "$secret"
}

arctl_login() {
  local _n
  for _n in $(seq 1 90); do
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
  warn "arctl user login failed after retries — is the gateway up so ${KEYCLOAK_ISSUER} resolves?"
  return 1
}

# mint_user_token — echo a Keycloak access token for admin-user (aud ar-backend).
# The same token authenticates arctl AND the gateway's JWT policy on the agent
# routes; its `sub` becomes the STS session name in CloudTrail.
mint_user_token() {
  curl -s -X POST "${KEYCLOAK_ISSUER}/protocol/openid-connect/token" \
    -d grant_type=password -d client_id="$AR_CLI_CLIENT" \
    -d username="$AS_USER" -d password="$AS_PASSWORD" | jq -r '.access_token // empty'
}
