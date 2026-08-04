#!/usr/bin/env bash
# lib.sh — shared helpers for agentic-verdict-hitl-kind.
#
# Sourced by every script under ./scripts/. Follows the inline-helpers
# convention used across the labs (each lab carries its own log/step/die so
# scripts are runnable standalone).

set -Eeuo pipefail

# Central product/infra versions (generated from versions.json). Sourcing this
# lets a version bump in one place flow to every lab; runtime env still wins.
# The := fallbacks keep the lab runnable if versions.env is absent (e.g. a dir
# copied out standalone, or the solo-labs mirror).
__versions_env="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/versions.env"
[ -f "$__versions_env" ] && . "$__versions_env"

# ── logging ───────────────────────────────────────────────────────────────────
__has_color() { [[ -t 2 ]] && command -v tput >/dev/null 2>&1; }
if __has_color; then
  __dim()  { tput dim;  printf '%s' "$*"; tput sgr0; }
  __ok()   { tput setaf 2; printf '✓ '; tput sgr0; printf '%s' "$*"; }
  __warn() { tput setaf 3; printf '! '; tput sgr0; printf '%s' "$*"; }
  __err()  { tput setaf 1; printf 'ERROR: '; tput sgr0; printf '%s' "$*"; }
  __step() { tput bold; printf '%s' "$*"; tput sgr0; }
else
  __dim()  { printf '%s' "$*"; }
  __ok()   { printf '✓ %s' "$*"; }
  __warn() { printf '! %s' "$*"; }
  __err()  { printf 'ERROR: %s' "$*"; }
  __step() { printf '%s' "$*"; }
fi
log()    { { __dim "  $*"; printf '\n'; } >&2; }
ok()     { { __ok "$*";    printf '\n'; } >&2; }
warn()   { { __warn "$*";  printf '\n'; } >&2; }
die()    { { __err "$*";   printf '\n'; } >&2; exit 1; }
step()   { printf '\n' >&2; { __step "══> $*"; printf '\n'; } >&2; }

require() { command -v "$1" >/dev/null 2>&1 || die "$1 not found — install it first"; }

# ── cluster constants ─────────────────────────────────────────────────────────
export CLUSTER_NAME="${CLUSTER_NAME:-verdict}"
export CTX="kind-${CLUSTER_NAME}"

# ── product versions ──────────────────────────────────────────────────────────
# Pinned to the LATEST Enterprise builds, deliberately ahead of the repo-wide
# versions.json matrix (which trails at AGW 2.3.4 / kagent-ent 0.4.3). This lab
# exists to exercise the current releases, so it pins its own:
#
#   AGW 2026.7.1      current Stable/LTS. 2026.7.0 added extended label
#                     selectors + default labelset support, which is what lets
#                     the verdict label pull in the HITL policy with no
#                     per-agent YAML. Do not drop below 2026.7.0.
#   kagent-ent 0.5.3  latest (2026-07-28), wraps kagent OSS 0.10.0-beta.
#   AR 2026.6.1       Enterprise AgentRegistry, matches the local arctl build.
export AGW_VERSION="${AGW_VERSION:-v2026.7.1}"
export AGW_CHARTS="${AGW_CHARTS:-oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts}"
export KAGENT_ENT_VERSION="${KAGENT_ENT_VERSION:-0.5.3}"
export KENT_CRDS_CHART="${KENT_CRDS_CHART:-oci://us-docker.pkg.dev/solo-public/kagent-enterprise-helm/charts/kagent-enterprise-crds}"
export KENT_CHART="${KENT_CHART:-oci://us-docker.pkg.dev/solo-public/kagent-enterprise-helm/charts/kagent-enterprise}"
export AR_VERSION="${AR_VERSION:-2026.6.1}"
export AR_CHART="${AR_CHART:-oci://us-docker.pkg.dev/solo-public/agentregistry-enterprise/helm/agentregistry-enterprise}"
export METALLB_VERSION="${METALLB_VERSION:-v0.14.9}"
export GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.5.1}"
export KYVERNO_VERSION="${KYVERNO_VERSION:-v1.13.4}"

# ── namespaces ────────────────────────────────────────────────────────────────
export AGW_NS="${AGW_NS:-agentgateway-system}"
export KAGENT_NS="${KAGENT_NS:-kagent}"
export AR_NS="${AR_NS:-agentregistry-system}"
export KEYCLOAK_NS="${KEYCLOAK_NS:-ar-keycloak}"
export KEYCLOAK_REALM="${KEYCLOAK_REALM:-agentregistry}"
export SRE_NS="${SRE_NS:-sre-tools}"
export HITL_NS="${HITL_NS:-hitl}"

# ── OIDC clients (from the realm import) ──────────────────────────────────────
export AR_BACKEND_CLIENT="${AR_BACKEND_CLIENT:-ar-backend}"
export AR_UI_CLIENT="${AR_UI_CLIENT:-ar-ui}"
export KAGENT_BACKEND_CLIENT="${KAGENT_BACKEND_CLIENT:-kagent-backend}"
export AR_CLI_CLIENT="${AR_CLI_CLIENT:-ar-cli-password}"
export RBAC_SUPERUSER_ROLE="${RBAC_SUPERUSER_ROLE:-admins}"
export AS_USER="${AS_USER:-admin-user}"
export AS_PASSWORD="${AS_PASSWORD:-password}"

# ── AgentRegistry server ──────────────────────────────────────────────────────
export AR_SERVER_SVC="${AR_SERVER_SVC:-agentregistry-enterprise-server}"
export AR_SERVER_PORT="${AR_SERVER_PORT:-12121}"

# ── the two agents this lab is about ──────────────────────────────────────────
# Same code, same tools, same MCP server. The ONLY difference is the verdict an
# external review process stamps on each one.
export GREEN_AGENT="${GREEN_AGENT:-sre-triage}"
export RED_AGENT="${RED_AGENT:-sre-remediate}"
export VERDICT_LABEL="${VERDICT_LABEL:-risk.platform.solo.io/verdict}"

# ── local image registry the arctl scaffolds push to ──────────────────────────
export REG_NAME="${REG_NAME:-kind-registry}"
export REG_PORT="${REG_PORT:-5001}"

# Image tags for the services we build + kind-load
export SRE_TOOLS_IMAGE="${SRE_TOOLS_IMAGE:-sre-tools:dev}"
export HITL_EXTAUTH_IMAGE="${HITL_EXTAUTH_IMAGE:-hitl-extauth:dev}"
export HITL_UI_IMAGE="${HITL_UI_IMAGE:-hitl-ui:dev}"

# where `arctl init agent` scaffolds — the lab's artifacts/ dir
LAB_ROOT_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
export LAB_ROOT="${LAB_ROOT:-$LAB_ROOT_DEFAULT}"
export ARTIFACTS_DIR="${ARTIFACTS_DIR:-$LAB_ROOT/artifacts}"

# arctl on PATH, clean output
export PATH="$HOME/.arctl/bin:$PATH"

# platform facts written by 02-agentgateway.sh (LB IP + sslip hostnames)
set -a
[ -f "$LAB_ROOT/.env.verdict" ] && . "$LAB_ROOT/.env.verdict"
set +a
[ -n "${LB:-}" ] && {
  : "${KEYCLOAK_HOST:=keycloak.${LB}.sslip.io}"
  : "${AR_HOST:=agentregistry.${LB}.sslip.io}"
  : "${MCP_HOST:=mcp.${LB}.sslip.io}"
  export KEYCLOAK_HOST AR_HOST MCP_HOST
}
export KEYCLOAK_ISSUER="${KEYCLOAK_ISSUER:-http://${KEYCLOAK_HOST:-keycloak.invalid}/realms/${KEYCLOAK_REALM}}"
export ARCTL_API_BASE_URL="${ARCTL_API_BASE_URL:-http://${AR_HOST:-agentregistry.invalid}}"

# ── secrets loader ────────────────────────────────────────────────────────────
# Enterprise everything, so this needs a Solo licence as well as a model key.
load_secrets() {
  SECRETS_FILE="${SECRETS_FILE:-$HOME/code/solo/secrets/secrets-envs.sh}"
  if [[ -f "$SECRETS_FILE" ]]; then
    set -a; source "$SECRETS_FILE"; set +a
  fi
  export SOLO_LICENSE_KEY="${SOLO_LICENSE_KEY:-${KAGENT_ENT_LICENSE_KEY:-${SOLO_ISTIO_LICENSE_KEY:-}}}"
  export KAGENT_ENT_LICENSE_KEY="${KAGENT_ENT_LICENSE_KEY:-$SOLO_LICENSE_KEY}"
  return 0
}

require_secrets() {
  load_secrets
  local missing=0
  [[ -n "${ANTHROPIC_API_KEY:-}" ]]  || { warn "ANTHROPIC_API_KEY not set"; missing=1; }
  [[ -n "${SOLO_LICENSE_KEY:-}" ]]   || { warn "SOLO_LICENSE_KEY not set";  missing=1; }
  if (( missing )); then
    cat >&2 <<'EOF'

This lab runs Solo Enterprise for agentgateway, kagent and AgentRegistry, so it
needs a licence key as well as a model key. Two ways to provide them:

  1. export in your current shell:
       export ANTHROPIC_API_KEY=sk-ant-...
       export SOLO_LICENSE_KEY=...
       ./scripts/quick.sh up

  2. point at a sourceable file:
       SECRETS_FILE=/path/to/secrets.sh ./scripts/quick.sh up

The Enterprise charts live in a private Google Artifact Registry, so you also
need `gcloud auth login` before running.
EOF
    exit 1
  fi
}

# gar_login — authenticate helm to the Solo enterprise chart registry.
gar_login() {
  local gar_host=us-docker.pkg.dev
  require gcloud
  gcloud auth print-access-token >/dev/null 2>&1 \
    || die "gcloud not authenticated — run: gcloud auth login"
  gcloud auth print-access-token \
    | helm registry login -u oauth2accesstoken --password-stdin "$gar_host" >/dev/null 2>&1 \
    && ok "helm authenticated to $gar_host"
}

# ── kubectl helpers ───────────────────────────────────────────────────────────
kc() { kubectl --context "$CTX" "$@"; }

# Poll for a deployment to exist (an operator may create it asynchronously) and
# then for it to become Available.
wait_deploy() {
  local ns="$1" name="$2" timeout="${3:-300s}"
  local end=$(( $(date +%s) + 120 ))
  until kc -n "$ns" get deployment "$name" >/dev/null 2>&1; do
    [[ $(date +%s) -ge $end ]] && { warn "deployment $ns/$name not created within 2m"; return 1; }
    sleep 3
  done
  kc -n "$ns" wait --for=condition=Available deployment/"$name" --timeout="$timeout" >/dev/null
}

check_docker() {
  docker info >/dev/null 2>&1 || die "docker daemon not reachable — start Docker Desktop / OrbStack"
}

# build_and_load — build an image on the host and load it onto the kind nodes.
# kind nodes cannot pull from a non-cached local build, so every custom image
# has to be explicitly loaded. Re-runs are no-ops.
build_and_load() {
  local context="$1" image="$2"
  log "docker build → $image"
  docker build --quiet -t "$image" "$context" >/dev/null
  ok "built $image"
  log "kind load → $image (cluster $CLUSTER_NAME)"
  kind load docker-image --name "$CLUSTER_NAME" "$image" >/dev/null
  ok "loaded $image into kind"
}

# helm_install_with_progress — like `helm upgrade --install --wait` but prints
# periodic pod-status snapshots while it blocks. The bare --wait flag is silent
# for minutes on cold clusters (Enterprise image pulls from GAR take 2-5 min),
# which reads as a hang.
helm_install_with_progress() {
  local release="$1" chart="$2" namespace="$3"
  shift 3
  helm --kube-context "$CTX" upgrade --install "$release" "$chart" \
    --namespace "$namespace" --create-namespace "$@" >/dev/null &
  local helm_pid=$!
  local start; start=$(date +%s)
  while kill -0 "$helm_pid" 2>/dev/null; do
    sleep 15
    kill -0 "$helm_pid" 2>/dev/null || break
    local elapsed=$(( $(date +%s) - start ))
    local pods_summary
    pods_summary=$(kc -n "$namespace" get pods --no-headers 2>/dev/null \
      | awk '{printf "%s[%s] ", $1, $2}')
    if [[ -n "$pods_summary" ]]; then
      log "[+${elapsed}s] pods: ${pods_summary}"
    else
      log "[+${elapsed}s] still pulling images / creating pods..."
    fi
  done
  wait "$helm_pid"
}

# bridge — map the sslip issuer hostname to Keycloak's ClusterIP on a
# deployment, via hostAliases. In-cluster clients (kagent controller, AR
# server) have to validate tokens against the SAME issuer string the browser
# sees, but that hostname resolves to the gateway LB which they cannot always
# reach. Pointing it straight at the Keycloak Service keeps one issuer string
# working from both sides.
bridge() {
  local dep="$1" ns="$2" ip
  ip="$(kc -n "$KEYCLOAK_NS" get svc keycloak -o jsonpath='{.spec.clusterIP}' 2>/dev/null)"
  [[ -n "$ip" ]] || return 0
  kc -n "$ns" patch deploy "$dep" --type=json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/hostAliases\",\"value\":[{\"ip\":\"$ip\",\"hostnames\":[\"$KEYCLOAK_HOST\"]}]}]" >/dev/null 2>&1 \
  || kc -n "$ns" patch deploy "$dep" --type=json \
    -p "[{\"op\":\"add\",\"path\":\"/spec/template/spec/hostAliases\",\"value\":[{\"ip\":\"$ip\",\"hostnames\":[\"$KEYCLOAK_HOST\"]}]}]" >/dev/null 2>&1 || true
}

# arctl_login — password-grant login against the realm, retried while Keycloak
# finishes its realm import.
arctl_login() {
  local _n
  for _n in $(seq 1 60); do
    curl -sf -m2 -o /dev/null "${KEYCLOAK_ISSUER}/.well-known/openid-configuration" && break
    sleep 1
  done
  for _n in 1 2 3 4 5; do
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
