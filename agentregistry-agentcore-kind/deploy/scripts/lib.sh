#!/usr/bin/env bash
# lib.sh — shared helpers for agentregistry-agentcore-kind.
#
# Story: scaffold + build an MCP server, a skill, and an agent with arctl, wire
# them together, then deploy the SAME agent to two runtimes — Solo Enterprise for
# kagent in a local kind cluster, and AWS Bedrock AgentCore. AgentRegistry is the
# catalog/control plane and runs IN the cluster (the v2026.6.1 in-cluster server,
# the way customers deploy it — the old local Docker `daemon` is gone). The whole
# platform is reached at http://*.localtest.me through an agentgateway ingress, so
# there are no kubectl port-forwards. `arctl` is the enterprise CLI (v2026.6.1);
# `arctl init/build/run` still build + run agents locally before you publish.

set -Eeuo pipefail

# Central product/infra versions (generated from versions.json). Sourcing this
# lets a version bump in one place flow to every lab; runtime env still wins.
__versions_env="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/versions.env"
[ -f "$__versions_env" ] && . "$__versions_env"
: "${AGW_ENT_VERSION:=v2.3.4}"; : "${AGW_OSS_VERSION:=v1.3.0-alpha.1}"; : "${AGW_CALVER_VERSION:=v2026.5.2}"

# Only use tput when stderr is a TTY AND $TERM is a real terminal. A notebook bash
# kernel has a pty (so -t 2 is true) but often no/empty $TERM, which makes tput print
# "tput: No value for $TERM and no -T specified"; treat unset/dumb $TERM as no-color.
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

# ── arctl version ─────────────────────────────────────────────────────────────
# v2026.6.1: AgentRegistry is the in-cluster server (the local `daemon` was
# dropped). `arctl user login` authenticates the CLI against Keycloak; `arctl
# init/build/run` still scaffold, build and run agents locally. 00-prereqs.sh
# installs/validates this version.
export ARCTL_VERSION="${ARCTL_VERSION:-v2026.6.1}"
export ARCTL_INSTALL_URL="${ARCTL_INSTALL_URL:-https://storage.googleapis.com/agentregistry-enterprise/install.sh}"

# ── roots ───────────────────────────────────────────────────────────────────
# Callers compute LAB_ROOT as SCRIPT_DIR/.., which is the `deploy/` folder (scripts,
# yaml, mcp, templates, kind, skill, plus gitignored .env.local/.agentcore all live
# under it). PROJECT_ROOT is its parent — the lab root where demo.ipynb lives and where
# a freshly scaffolded agent (agentdemo/) is created. Use PROJECT_ROOT for the agent dir.
export PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ── cluster ─────────────────────────────────────────────────────────────────
export CLUSTER_NAME="${CLUSTER_NAME:-agentcore-demo}"
export CTX="kind-${CLUSTER_NAME}"
export GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.4.0}"

# Local OCI registry the arctl scaffolds push to (localhost:5001 by default).
export REG_NAME="${REG_NAME:-kind-registry}"
export REG_PORT="${REG_PORT:-5001}"

# ── Keycloak (OIDC issuer for AgentRegistry + kagent) ────────────────────────
# Realm `agentregistry` with the v2026.6.1 clients: ar-backend / ar-ui /
# ar-cli-interactive / ar-cli-password (registry) and kagent-backend / kagent-ui
# (kagent), plus a lab-added kagent-cli-password (so ask.sh can mint a kagent-aud
# token by script). Issuer is http://keycloak.localtest.me (port 80): the browser
# and host-side arctl reach it via the agentgateway ingress; in-cluster pods reach
# it via a hostAlias -> Keycloak ClusterIP. Group claim `Groups`; superuser group
# `admins`; user admin-user/password.
export KEYCLOAK_NS="${KEYCLOAK_NS:-keycloak}"
export KEYCLOAK_REALM="${KEYCLOAK_REALM:-agentregistry}"
export KEYCLOAK_HOST="${KEYCLOAK_HOST:-keycloak.localtest.me}"   # served on :80 via the gateway
export KEYCLOAK_ISSUER="${KEYCLOAK_ISSUER:-http://${KEYCLOAK_HOST}/realms/${KEYCLOAK_REALM}}"
# Where ask.sh mints tokens FROM, in-cluster (the svc; KC_HOSTNAME stamps the
# localtest.me `iss` regardless of which URL is hit).
export KEYCLOAK_MINT_URL="${KEYCLOAK_MINT_URL:-http://keycloak.${KEYCLOAK_NS}.svc.cluster.local:8080/realms/${KEYCLOAK_REALM}}"
# OIDC clients (see yaml/keycloak/agentregistry-realm.json).
export AR_CLI_CLIENT="${AR_CLI_CLIENT:-ar-cli-password}"          # scripted arctl login (password grant; aud ar-backend)
export AR_UI_CLIENT="${AR_UI_CLIENT:-ar-ui}"
export AR_BACKEND_CLIENT="${AR_BACKEND_CLIENT:-ar-backend}"
export KAGENT_BACKEND_CLIENT="${KAGENT_BACKEND_CLIENT:-kagent-backend}"
export KAGENT_UI_CLIENT="${KAGENT_UI_CLIENT:-kagent-ui}"
export KAGENT_CLI_CLIENT="${KAGENT_CLI_CLIENT:-kagent-cli-password}"  # ask.sh scripted mint (aud kagent-backend)
export AS_USER="${AS_USER:-admin-user}"
export AS_PASSWORD="${AS_PASSWORD:-password}"
export RBAC_SUPERUSER_ROLE="${RBAC_SUPERUSER_ROLE:-admins}"

# ── agentgateway ingress (everything at *.localtest.me, no port-forwards) ─────
# enterprise-agentgateway serves an ingress Gateway whose NodePort 30080 is mapped
# to host :80 by the kind config. *.localtest.me -> 127.0.0.1 -> host :80 -> gateway
# -> HTTPRoute -> service.
export GW_NS="${GW_NS:-agentgateway-system}"
export GW_NAME="${GW_NAME:-agentgateway-proxy}"
export GW_HTTP_NODEPORT="${GW_HTTP_NODEPORT:-30080}"
export AR_HOST="${AR_HOST:-agentregistry.localtest.me}"
export KAGENT_UI_HOST="${KAGENT_UI_HOST:-kagent.localtest.me}"

# ── AgentRegistry (in-cluster, v2026.6.1) ────────────────────────────────────
export AR_NS="${AR_NS:-agentregistry-system}"
export AR_VERSION="${AR_VERSION:-2026.6.1}"
export AR_CHART="${AR_CHART:-oci://us-docker.pkg.dev/solo-public/agentregistry-enterprise/helm/agentregistry-enterprise}"
export AR_SERVER_SVC="${AR_SERVER_SVC:-agentregistry-enterprise-server}"
export AR_SERVER_PORT="${AR_SERVER_PORT:-12121}"
# Runtimes report telemetry here (the AR chart's bundled collector).
export AR_TELEMETRY_ENDPOINT="${AR_TELEMETRY_ENDPOINT:-http://agentregistry-enterprise-telemetry-collector.${AR_NS}.svc.cluster.local:4318}"
# arctl + the UI talk to the server through the gateway (no port-forward).
export ARCTL_API_BASE_URL="${ARCTL_API_BASE_URL:-http://${AR_HOST}}"
# The kagent runtime points at the in-cluster controller Service directly.
export KAGENT_URL="${KAGENT_URL:-http://kagent-controller.kagent:8083}"
# Where the scaffolded artifact projects live (relative to the lab root).
export ARTIFACTS_DIR="${ARTIFACTS_DIR:-artifacts}"

# ── Telemetry: Solo Enterprise management chart (kagent Tracing/Agents/Policies) ─
# The Enterprise UI (kagent.localtest.me) reads kagent agent traces from its own
# ClickHouse; agents export OTLP to this collector. (AgentRegistry has its own
# bundled telemetry above for deployment monitoring.)
export SOLO_MGMT_NS="${SOLO_MGMT_NS:-solo-enterprise}"
export SOLO_ENT_MGMT_VERSION="${SOLO_ENT_MGMT_VERSION:-0.4.3}"
export TELEMETRY_COLLECTOR_ENDPOINT="${TELEMETRY_COLLECTOR_ENDPOINT:-http://solo-enterprise-telemetry-collector.${SOLO_MGMT_NS}.svc.cluster.local:4317}"

# bridge_keycloak_hostalias <deployment> [namespace] — add/replace a hostAlias
# mapping the issuer host (keycloak.localtest.me) to Keycloak's ClusterIP on a
# deployment, so its pods resolve the gateway-style issuer in-cluster (the AR
# server, the kagent controller and the Enterprise UI all do OIDC discovery
# against it). Idempotent.
bridge_keycloak_hostalias() {
  local dep="$1" ns="${2:-kagent}" host="$KEYCLOAK_HOST" ip
  ip="$(kc -n "$KEYCLOAK_NS" get svc keycloak -o jsonpath='{.spec.clusterIP}' 2>/dev/null)"
  [[ -n "$ip" ]] || { warn "keycloak ClusterIP not found; skipping hostAlias on $ns/$dep"; return 0; }
  kc -n "$ns" patch deploy "$dep" --type=json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/hostAliases\",\"value\":[{\"ip\":\"$ip\",\"hostnames\":[\"$host\"]}]}]" >/dev/null 2>&1 \
  || kc -n "$ns" patch deploy "$dep" --type=json \
    -p "[{\"op\":\"add\",\"path\":\"/spec/template/spec/hostAliases\",\"value\":[{\"ip\":\"$ip\",\"hostnames\":[\"$host\"]}]}]" >/dev/null 2>&1 || true
}

# ── Solo Enterprise for kagent ──────────────────────────────────────────────
export KAGENT_ENT_VERSION="${KAGENT_ENT_VERSION:-0.4.3}"
export KENT_CRDS_CHART="${KENT_CRDS_CHART:-oci://us-docker.pkg.dev/solo-public/kagent-enterprise-helm/charts/kagent-enterprise-crds}"
export KENT_CHART="${KENT_CHART:-oci://us-docker.pkg.dev/solo-public/kagent-enterprise-helm/charts/kagent-enterprise}"
export GAR_HOST="${GAR_HOST:-us-docker.pkg.dev}"

# ── secrets ─────────────────────────────────────────────────────────────────
# Required: ANTHROPIC_API_KEY (agent model) + SOLO_LICENSE_KEY (Solo Enterprise
# for kagent). KAGENT_ENT_LICENSE_KEY overrides if your kagent key is separate.
# AgentRegistry itself needs no license. The two confidential client secrets
# (ar-backend, kagent-backend) are scraped from Keycloak at runtime by 02-keycloak.sh.
load_secrets() {
  local lab_root; lab_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  if [[ -f "$lab_root/.env.local" ]]; then
    set -a; source "$lab_root/.env.local"; set +a
  fi
  if [[ -n "${SECRETS_FILE:-}" ]]; then
    [[ -f "$SECRETS_FILE" ]] || die "SECRETS_FILE='$SECRETS_FILE' does not exist"
    set -a; source "$SECRETS_FILE"; set +a
  fi
  export KAGENT_ENT_LICENSE_KEY="${KAGENT_ENT_LICENSE_KEY:-${SOLO_LICENSE_KEY:-}}"
  export SOLO_ISTIO_LICENSE_KEY="${SOLO_ISTIO_LICENSE_KEY:-${SOLO_LICENSE_KEY:-}}"
}
require_secrets() {
  load_secrets
  local missing=()
  [[ -z "${ANTHROPIC_API_KEY:-}" ]]      && missing+=("ANTHROPIC_API_KEY")
  [[ -z "${KAGENT_ENT_LICENSE_KEY:-}" ]] && missing+=("SOLO_LICENSE_KEY (or KAGENT_ENT_LICENSE_KEY)")
  if (( ${#missing[@]} > 0 )); then
    cat >&2 <<EOF

ERROR: missing required env vars: ${missing[*]}

  export ANTHROPIC_API_KEY=sk-ant-...
  export SOLO_LICENSE_KEY=...            # Solo Enterprise for kagent
  ./scripts/quick.sh up

  or:  SECRETS_FILE=/path/to/secrets.sh ./scripts/quick.sh up
EOF
    exit 1
  fi
}

kc(){ kubectl --context "$CTX" "$@"; }
check_docker(){ docker info >/dev/null 2>&1 || die "docker daemon not reachable"; }

# decode_jwt — print a JWT payload (2nd segment) as pretty JSON. Reads $1 or stdin.
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
# resolve_kagent_agent [prefix] — print the kagent Agent CRD name whose name
# starts with prefix (default "summarizer").
resolve_kagent_agent() {
  kc -n kagent get agents.kagent.dev -o name 2>/dev/null | sed 's#.*/##' | grep -i "^${1:-summarizer}" | head -1
}
wait_agent() {
  local name="$1" timeout="${2:-300}"; local end=$(( $(date +%s) + timeout ))
  until [[ "$(kc -n kagent get agent "$name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == "True" ]]; do
    [[ $(date +%s) -ge $end ]] && { warn "agent $name not Ready in ${timeout}s"; return 1; }; sleep 5
  done
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

# ensure_gar_auth — gcloud + helm OCI login for the Solo public GAR (charts are
# public but helm OCI pull still needs a token).
ensure_gar_auth() {
  local host="${1:-$GAR_HOST}"
  command -v gcloud >/dev/null 2>&1 || die "gcloud required for the Solo enterprise charts ($host). Install: brew install --cask google-cloud-sdk; gcloud auth login"
  if ! gcloud auth print-access-token >/dev/null 2>&1; then
    [[ -t 0 ]] || die "gcloud not authenticated and no TTY. Run: gcloud auth login"
    gcloud auth login || die "gcloud auth login failed"
  fi
  gcloud auth print-access-token | helm registry login -u oauth2accesstoken --password-stdin "$host" >/dev/null \
    || die "helm registry login failed for $host"
}

# keycloak_client_secret <clientId> — print a confidential client's secret by
# querying the Keycloak admin API (admin/admin on the master realm) via a
# short-lived port-forward. Used by 02-keycloak.sh to wire ar-backend /
# kagent-backend into the AR + kagent installs.
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

# arctl_login — log the CLI in to the in-cluster registry as admin-user via the
# password-credentials flow (ar-cli-password client, scriptable; aud ar-backend).
# After this, arctl commands use the token in the OS keychain — no per-call token.
# Needs the issuer (keycloak.localtest.me) reachable from the host, i.e. the
# agentgateway ingress must be up first.
arctl_login() {
  # The issuer (keycloak.localtest.me) is served by the agentgateway ingress, which
  # reports the Gateway Programmed a beat before the route actually serves traffic.
  # setup.sh calls this straight after 06-gateway.sh, so a single-shot login loses
  # that race and 04b then dies with "API client not initialized". Wait for the OIDC
  # discovery doc to answer (up to ~90s), then retry the login a few times — the
  # gateway can serve the issuer a moment before the ar-backend is ready to mint.
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

# arctl_token — echo a raw bearer for the registry (admin-user, aud ar-backend).
# Most arctl verbs read the keychain after arctl_login, but `arctl runtime setup`
# authenticates ONLY via --registry-token / ARCTL_API_TOKEN (v2026.6.1 makes it a
# server call). Callers do:  export ARCTL_API_TOKEN="$(arctl_token)"  before it.
arctl_token() {
  curl -s -X POST "${KEYCLOAK_ISSUER}/protocol/openid-connect/token" \
    -d grant_type=password -d client_id="$AR_CLI_CLIENT" \
    -d username="$AS_USER" -d password="$AS_PASSWORD" | jq -r '.access_token // empty'
}

# --- GCP agent teardown workaround (released-image bug) ----------------------
# The GeminiAgentRuntime adapter stores a deployed agent's remoteId as the agent
# NAME (e.g. "agentdemo") instead of the Vertex reasoning-engine resource path, so
# arctl's Undeploy calls DeleteReasoningEngine(Name="agentdemo"). The Vertex API
# reads "agentdemo" as the PROJECT and returns BILLING_DISABLED for project
# "agentdemo"; the delete never succeeds, the finalizer never clears, and the
# Deployment row wedges in `terminating`, blocking the next GCP agent deploy. Until
# the image is fixed, the lab deletes the real engine itself and hard-purges the row.

# _gcp_delete_vertex_engine DISPLAYNAME — delete the Vertex reasoning engine(s) whose
# displayName matches, by full resource path (what arctl should do but can't).
# No-op without gcloud / an access token / a project.
_gcp_delete_vertex_engine() {
  local dn="$1" proj loc tok eng e
  command -v gcloud >/dev/null 2>&1 || return 0
  proj="${GCP_PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"; [ -n "$proj" ] || return 0
  loc="${GCP_LOCATION:-us-central1}"
  tok="$(gcloud auth print-access-token 2>/dev/null)"; [ -n "$tok" ] || return 0
  eng="$(curl -s -H "Authorization: Bearer $tok" \
    "https://${loc}-aiplatform.googleapis.com/v1/projects/${proj}/locations/${loc}/reasoningEngines" 2>/dev/null \
    | DN="$dn" python3 -c 'import sys,json,os
try: d=json.load(sys.stdin)
except Exception: d={}
[print(x["name"]) for x in d.get("reasoningEngines",[]) if x.get("displayName")==os.environ["DN"]]' 2>/dev/null)"
  for e in $eng; do
    curl -s -X DELETE -H "Authorization: Bearer $tok" \
      "https://${loc}-aiplatform.googleapis.com/v1/${e}?force=true" >/dev/null 2>&1 && ok "deleted Vertex engine ${e##*/} (displayName $dn)"
  done
}

# _force_purge_deployment NAME — hard-delete a registry Deployment row from Postgres.
# Use ONLY after the real cloud resource is gone; needed because the broken Undeploy
# above leaves the row wedged in `terminating` with an uncleaable finalizer, and
# clearing the finalizer alone does not trigger GC (verified) — the row must be deleted.
_force_purge_deployment() {
  local name="$1" pg
  pg="$(kc -n agentregistry-system get pods -l app.kubernetes.io/name=postgresql -o name 2>/dev/null | head -1)"
  [ -n "$pg" ] || pg="$(kc -n agentregistry-system get pods --no-headers 2>/dev/null | awk '/enterprise-postgresql/{print "pod/"$1; exit}')"
  [ -n "$pg" ] || { log "force-purge: no registry postgres pod found for '$name'"; return 1; }
  kc -n agentregistry-system exec "${pg#pod/}" -- sh -c \
    "PGPASSWORD=\$POSTGRES_PASSWORD psql -U agentregistry -d agentregistry -c \"DELETE FROM deployments WHERE name='$name';\"" >/dev/null 2>&1 \
    && ok "force-purged stuck deployment row '$name'" || log "force-purge of '$name' failed"
}

# _dep_present NAME — true if a Deployment row (incl. terminating) is listed.
_dep_present() { arctl get deployments 2>/dev/null | awk -v n="$1" '{split($1,a,"/"); if (a[2]==n||$1==n) f=1} END{exit f?0:1}'; }

# gcp_reset_agent DEPLOY_NAME AGENT_DISPLAYNAME — fully clear a prior GCP agent
# deployment so a fresh one can apply: delete the real Vertex engine, arctl-delete the
# row (graceful), and force-purge it if the broken Undeploy wedges it in terminating.
gcp_reset_agent() {
  local dep="$1" name="$2" i
  _gcp_delete_vertex_engine "$name"
  _dep_present "$dep" || return 0
  arctl delete deployment "$dep" >/dev/null 2>&1 || true
  for i in $(seq 1 10); do _dep_present "$dep" || { ok "cleared $dep"; return 0; }; sleep 2; done
  log "'$dep' stuck terminating (GeminiAgentRuntime Undeploy bug) — force-purging the registry row"
  _force_purge_deployment "$dep"
  for i in $(seq 1 15); do _dep_present "$dep" || { ok "cleared $dep"; return 0; }; sleep 2; done
  log "warning: '$dep' still present after force-purge"
}
