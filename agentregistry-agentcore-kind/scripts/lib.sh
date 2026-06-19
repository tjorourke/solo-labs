#!/usr/bin/env bash
# lib.sh — shared helpers for agentregistry-agentcore-kind.
#
# Story: scaffold + build an MCP server, a skill, and an agent with arctl, wire
# them together, then deploy the SAME agent to two runtimes — Solo Enterprise
# for kagent in a local kind cluster, and AWS Bedrock AgentCore. The local
# arctl daemon (localhost:12121) is the catalog/control plane: a Kubernetes
# Runtime points it at the kind cluster (Deployment lands as kagent CRDs) and a
# BedrockAgentCore Runtime points it at your AWS account (Deployment lands as an
# AgentCore runtime). Anthropic Claude is the model in both. arctl is the
# enterprise build; it must be a version that still ships the local `daemon`
# (v2026.5.4 is the latest such — v2026.6.x drops it in favour of a
# cluster-hosted server). 00-prereqs.sh installs/validates the right one.

set -Eeuo pipefail

# Central product/infra versions (generated from versions.json). Sourcing this
# lets a version bump in one place flow to every lab; runtime env still wins.
# Mirrored into solo-labs too (sync-to-labs.sh). The := fallbacks keep a lab
# runnable even if versions.env is absent (e.g. a dir copied out standalone).
__versions_env="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/versions.env"
[ -f "$__versions_env" ] && . "$__versions_env"
: "${AGW_ENT_VERSION:=v2.3.4}"; : "${AGW_OSS_VERSION:=v1.3.0-alpha.1}"; : "${AGW_CALVER_VERSION:=v2026.5.2}"

__has_color() { [[ -t 2 ]] && command -v tput >/dev/null 2>&1; }
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
# Pin the enterprise arctl. Must still have the `daemon` subcommand, so the
# latest usable line is v2026.5.4 (v2026.6.x assumes a cluster-hosted server).
export ARCTL_VERSION="${ARCTL_VERSION:-v2026.5.4}"
export ARCTL_INSTALL_URL="${ARCTL_INSTALL_URL:-https://storage.googleapis.com/agentregistry-enterprise/install.sh}"

# ── cluster ─────────────────────────────────────────────────────────────────
export CLUSTER_NAME="${CLUSTER_NAME:-agentcore-demo}"
export CTX="kind-${CLUSTER_NAME}"
export GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.4.0}"

# Local OCI registry the arctl scaffolds push to (localhost:5001 by default).
export REG_NAME="${REG_NAME:-kind-registry}"
export REG_PORT="${REG_PORT:-5001}"

# ── Keycloak (OIDC issuer the enterprise kagent controller validates against) ─
# Enterprise kagent's controller does OIDC discovery at startup and refuses to
# run without a reachable issuer, so we deploy the shared `solo` realm.
export KEYCLOAK_NS="${KEYCLOAK_NS:-keycloak}"
export KEYCLOAK_REALM="${KEYCLOAK_REALM:-solo}"
export KEYCLOAK_CLIENT="${KEYCLOAK_CLIENT:-kagent}"
# The issuer host. keycloak.localtest.me resolves to 127.0.0.1 via PUBLIC DNS,
# so the browser reaches the issuer with no /etc/hosts; in-cluster pods reach it
# via a hostAlias -> Keycloak ClusterIP (bridge_keycloak_hostalias). Same `iss`
# on both sides, which is what lets the kagent UI's OIDC login work on kind.
# Port 18080 (not 8080) on purpose: a local `arctl run` agent binds host :8080
# for its A2A chat (the chat URL is hardcoded to localhost:8080 in arctl), so the
# Keycloak issuer lives on a high port to avoid shadowing it. Keycloak still
# listens on 8080 inside the cluster; only its host/issuer port is 18080.
export KEYCLOAK_OIDC_HOST="${KEYCLOAK_OIDC_HOST:-keycloak.localtest.me:18080}"
# What the controller/oauth2-proxy validate (and the token `iss`).
export KEYCLOAK_ISSUER="${KEYCLOAK_ISSUER:-http://${KEYCLOAK_OIDC_HOST}/realms/${KEYCLOAK_REALM}}"
# Where ask.sh mints tokens FROM, in-cluster (the svc; KC_HOSTNAME stamps the
# localtest.me `iss` regardless of which URL is hit). Distinct from the issuer
# because a pod can't resolve keycloak.localtest.me to the host.
export KEYCLOAK_MINT_URL="${KEYCLOAK_MINT_URL:-http://keycloak.${KEYCLOAK_NS}.svc.cluster.local:8080/realms/${KEYCLOAK_REALM}}"

# ── Registry daemon behind Keycloak (so it forwards the user's token to kagent) ─
# The daemon is a Docker container; to validate Keycloak bearers it must resolve
# and reach the issuer host. We expose Keycloak + the kagent controller on the
# kind node via NodePorts, and run a socat container whose Docker network-alias
# IS the issuer host (keycloak.localtest.me), forwarding :18080 -> node:KEYCLOAK_NODEPORT.
export DAEMON_CONTAINER="${DAEMON_CONTAINER:-agentregistry-enterprise-server}"
export DAEMON_NETWORK="${DAEMON_NETWORK:-agentregistry_agentregistry-network}"
export ALIAS_CONTAINER="${ALIAS_CONTAINER:-arctl-keycloak-alias}"
export KEYCLOAK_NODEPORT="${KEYCLOAK_NODEPORT:-30080}"     # node -> Keycloak (for the daemon's OIDC discovery)
export CONTROLLER_NODEPORT="${CONTROLLER_NODEPORT:-30083}" # node -> kagent controller (the Kagent runtime's kagentUrl)
export KAGENT_URL="${KAGENT_URL:-http://${CLUSTER_NAME}-control-plane:${CONTROLLER_NODEPORT}}"
export RBAC_SUPERUSER_ROLE="${RBAC_SUPERUSER_ROLE:-field-fte}"  # alice's group -> registry superuser

# ── Telemetry: Solo Enterprise management chart (ClickHouse + OTel collectors) ──
# The AR UI Tracing tab queries ClickHouse (platformdb.otel_traces_json). Agents
# export OTLP -> the telemetry collector -> ClickHouse; the daemon (Docker) reads
# ClickHouse via a NodePort on the kind node.
export SOLO_MGMT_NS="${SOLO_MGMT_NS:-solo-enterprise}"
# Version of solo-public/solo-enterprise-helm/charts/management (ClickHouse +
# telemetry + the Solo Enterprise UI). This is the kagent enterprise release line
# (0.4.3), NOT the Istio mgmt-plane SOLO_MGMT_VERSION from versions.env (2.12.x) —
# a name collision, so keep this its own variable or the helm pull 404s.
export SOLO_ENT_MGMT_VERSION="${SOLO_ENT_MGMT_VERSION:-0.4.3}"
export CLICKHOUSE_SVC="${CLICKHOUSE_SVC:-solo-mgmt-clickhouse}"
export CLICKHOUSE_NATIVE_PORT="${CLICKHOUSE_NATIVE_PORT:-9000}"
export CLICKHOUSE_NODEPORT="${CLICKHOUSE_NODEPORT:-30900}"
export TELEMETRY_COLLECTOR_ENDPOINT="${TELEMETRY_COLLECTOR_ENDPOINT:-http://solo-enterprise-telemetry-collector.${SOLO_MGMT_NS}.svc.cluster.local:4317}"
# What the daemon validates traces against (config.go: CLICKHOUSE_*). ADDR is the
# kind node (reachable from the daemon over the kind network), via the NodePort.
export CLICKHOUSE_ADDR="${CLICKHOUSE_ADDR:-${CLUSTER_NAME}-control-plane}"
export CLICKHOUSE_PORT="${CLICKHOUSE_PORT:-${CLICKHOUSE_NODEPORT}}"
export CLICKHOUSE_DB="${CLICKHOUSE_DB:-platformdb}"
export CLICKHOUSE_USER="${CLICKHOUSE_USER:-default}"
export CLICKHOUSE_PASSWORD="${CLICKHOUSE_PASSWORD:-password}"

# bridge_keycloak_hostalias <deployment> — add/replace a hostAlias mapping the
# issuer host (keycloak.localtest.me) to Keycloak's ClusterIP on a deployment,
# so its pods resolve the browser-style issuer in-cluster. Idempotent.
bridge_keycloak_hostalias() {
  local dep="$1" host="${KEYCLOAK_OIDC_HOST%%:*}" ip
  ip="$(kc -n "$KEYCLOAK_NS" get svc keycloak -o jsonpath='{.spec.clusterIP}' 2>/dev/null)"
  [[ -n "$ip" ]] || { warn "keycloak ClusterIP not found; skipping hostAlias on $dep"; return 0; }
  kc -n kagent patch deploy "$dep" --type=json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/hostAliases\",\"value\":[{\"ip\":\"$ip\",\"hostnames\":[\"$host\"]}]}]" >/dev/null 2>&1 \
  || kc -n kagent patch deploy "$dep" --type=json \
    -p "[{\"op\":\"add\",\"path\":\"/spec/template/spec/hostAliases\",\"value\":[{\"ip\":\"$ip\",\"hostnames\":[\"$host\"]}]}]" >/dev/null 2>&1 || true
}

# ── Solo Enterprise for kagent ──────────────────────────────────────────────
export KAGENT_ENT_VERSION="${KAGENT_ENT_VERSION:-0.4.3}"
export KENT_CRDS_CHART="${KENT_CRDS_CHART:-oci://us-docker.pkg.dev/solo-public/kagent-enterprise-helm/charts/kagent-enterprise-crds}"
export KENT_CHART="${KENT_CHART:-oci://us-docker.pkg.dev/solo-public/kagent-enterprise-helm/charts/kagent-enterprise}"
export GAR_HOST="${GAR_HOST:-us-docker.pkg.dev}"

# ── arctl / AgentRegistry ───────────────────────────────────────────────────
export ARCTL_API_BASE_URL="${ARCTL_API_BASE_URL:-http://localhost:12121}"
# Where the scaffolded artifact projects live (relative to the lab root).
export ARTIFACTS_DIR="${ARTIFACTS_DIR:-artifacts}"

# ── secrets ─────────────────────────────────────────────────────────────────
# Required: ANTHROPIC_API_KEY (agent model) + SOLO_LICENSE_KEY (Solo Enterprise
# for kagent). KAGENT_ENT_LICENSE_KEY overrides if your kagent key is separate.
load_secrets() {
  # The gitignored .env.local written by setup-env.sh is the primary source.
  # (It may itself set SECRETS_FILE, so source it first.)
  local lab_root; lab_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  if [[ -f "$lab_root/.env.local" ]]; then
    set -a; source "$lab_root/.env.local"; set +a
  fi
  if [[ -n "${SECRETS_FILE:-}" ]]; then
    [[ -f "$SECRETS_FILE" ]] || die "SECRETS_FILE='$SECRETS_FILE' does not exist"
    set -a; source "$SECRETS_FILE"; set +a
  fi
  export KAGENT_ENT_LICENSE_KEY="${KAGENT_ENT_LICENSE_KEY:-${SOLO_LICENSE_KEY:-}}"
  # Solo Istio (the waypoint mesh) is licensed by the same Solo enterprise key,
  # so SOLO_LICENSE_KEY alone satisfies 05-waypoint.sh. Only agentgateway needs
  # its own AGENTGATEWAY_LICENSE_KEY.
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
# starts with prefix (default "summarizer"). The registry suffixes the agent
# with its tag + deployment name (e.g. summarizer-latest-summarizer-kagen).
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

# arctl_token — mint alice's Keycloak bearer and export it as ARCTL_API_TOKEN.
# The registry daemon runs behind the SAME Keycloak as kagent (04-daemon), so the
# setup scripts authenticate as a real user (alice: field-fte -> registry superuser
# + kagent Admin) and that one token is also forwarded to the kagent controller on
# deploy. Keycloak isn't on the host, so mint via a short-lived port-forward; setup
# runs in a normal shell, so backgrounding it here is fine (the notebook can't —
# connect.sh uses the persistent open-consoles forward instead).
arctl_token() {
  local user="${AS_USER:-alice}" pf tok
  kc -n "$KEYCLOAK_NS" port-forward svc/keycloak 18080:8080 >/dev/null 2>&1 & pf=$!
  for _ in $(seq 1 30); do
    curl -sf -m2 "http://localhost:18080/realms/${KEYCLOAK_REALM}/.well-known/openid-configuration" >/dev/null 2>&1 && break; sleep 1
  done
  tok="$(curl -s -X POST "http://localhost:18080/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d "grant_type=password&client_id=${KEYCLOAK_CLIENT}&username=${user}&password=${user}" \
    2>/dev/null | jq -r '.access_token // empty' 2>/dev/null)"
  kill "$pf" 2>/dev/null || true
  if [[ -n "$tok" ]]; then export ARCTL_API_TOKEN="$tok"; fi
}
