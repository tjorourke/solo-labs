#!/usr/bin/env bash
# gcp-deploy.sh — deploy the scaffolded agent + its MCP tool to the Google Cloud
# GeminiAgentRuntime ('gcp-vertex') that 04e-connect-gcp.sh registered at setup.
# Per-agent work only (the runtime + SA already exist):
#   MCP server  -> Cloud Run   (built from git source)
#   agent       -> Vertex AI Agent Engine (built from git source)
#
# Google is NOT like kagent here. Two things differ from the in-cluster path:
#   1. The agent's MCP tools are NOT auto-wired. The MCP must be deployed to
#      Cloud Run FIRST and then linked from the agent's Deployment via
#      spec.deploymentRefs, or the agent deploy is rejected.
#   2. The Cloud Run source builder only builds a Dockerfile at the REPO ROOT
#      (a subdir build path is applied twice and fails), so the MCP source is
#      pushed to its own root branch.
#
# So the order is: push MCP source -> deploy MCP -> wait Ready -> deploy agent.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
# Notebook bash kernels run with a minimal PATH; make the tools reachable.
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.arctl/bin:$PATH"
load_secrets
arctl_login
cd "$LAB_ROOT"

# ── config (override via env) ────────────────────────────────────────────────
GCP_RUNTIME_ID="${GCP_RUNTIME_ID:-gcp-vertex}"
AGENT="${AGENT:-agentdemo}"
MCP_NAME="${MCP_NAME:-my-mcp}"
AGENT_DEPLOY="${GCP_AGENT_DEPLOY:-${AGENT}-gcp}"     # Deployment names must be unique per runtime
MCP_DEPLOY="${GCP_MCP_DEPLOY:-${MCP_NAME}-gcp}"      # (kagent already uses '${MCP_NAME}'/'${AGENT}')
AGENT_BR="${AGENT_GIT_BRANCH:-main}"                 # agent source: subfolder '${AGENT}' on this branch
MCP_BR="${GCP_MCP_BRANCH:-gcp-mcp}"                  # MCP source: repo ROOT on this branch (Cloud Run build)

# reset_deployment NAME — delete a prior Deployment and WAIT for it to be purged.
# arctl delete is async: the row goes to `terminating` and a background GC removes
# it only once the runtime-side teardown (Cloud Run / Vertex) finishes. Re-applying
# before it's gone is rejected with "object ... is terminating", so a plain
# delete-then-apply races on every re-run.
# NOTE: `arctl get deployment NAME` (single) HIDES terminating rows (reports
# not-found), so it can't tell "purged" from "still terminating". The LIST
# (`arctl get deployments`) does show terminating rows, so poll that instead.
_dep_present() { arctl get deployments 2>/dev/null | awk -v n="$1" '{split($1,a,"/"); if (a[2]==n||$1==n) f=1} END{exit f?0:1}'; }
reset_deployment() {
  local name="$1" i
  _dep_present "$name" || return 0   # nothing to remove
  arctl delete deployment "$name" >/dev/null 2>&1 || true
  for i in $(seq 1 60); do
    _dep_present "$name" || { ok "cleared previous $name"; return 0; }
    log "waiting for previous '$name' to finish terminating [$i/60]"; sleep 5
  done
  log "warning: '$name' still terminating after 5m — its runtime teardown may be stuck (e.g. GCP billing disabled on the project the row was created under); the apply below may fail until the row is purged"
}

step "Preflight"
: "${AGENT_GIT_URL:?set AGENT_GIT_URL in .env.local}"
[[ -d "$AGENT" ]] || die "no $AGENT/ project — scaffold it first (Step 1)"
arctl get runtime "$GCP_RUNTIME_ID" >/dev/null 2>&1 \
  || die "Google platform '$GCP_RUNTIME_ID' not connected — run ./scripts/04e-connect-gcp.sh with a real GCP_SA_KEY_FILE"
TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-$(gh auth token 2>/dev/null)}}"
[[ -n "$TOKEN" ]] || die "no GitHub token in this shell — run \`gh auth token\` in a terminal, or export GH_TOKEN"
SLUG="${AGENT_GIT_URL#https://github.com/}"; SLUG="${SLUG%.git}"
GITURL="https://x-access-token:${TOKEN}@github.com/${SLUG}.git"
ok "platform $GCP_RUNTIME_ID ready · source repo $SLUG"

step "Ensuring the agent declares litellm, then pushing its source"
# Vertex AI Agent Engine resolves a base image where LiteLLM is NOT bundled, so an
# Anthropic-via-LiteLlm agent crashes at startup ("LiteLLM support requires pip
# install google-adk[extensions]") unless litellm is an explicit dependency.
# Harmless on kagent/AgentCore (their base image bundles it). Inject if missing.
PYPROJECT="$AGENT/pyproject.toml"
if [[ -f "$PYPROJECT" ]] && ! grep -q '"litellm"' "$PYPROJECT"; then
  python3 - "$PYPROJECT" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("dependencies = [", 'dependencies = [\n  "litellm",  # required by Vertex AI Agent Engine (LiteLlm not in its base image)', 1)
open(p, "w").write(s)
PY
  log "added litellm to $PYPROJECT"
fi
bash "$SCRIPT_DIR/git-push.sh" 2>&1 | sed 's/^/  /'

step "Pushing the MCP source to a repo-root branch ($MCP_BR) for Cloud Run"
# Cloud Run's source builder only finds a Dockerfile at the repo root, so push the
# MCP project's contents (not as a subfolder) to a dedicated branch.
T="$(mktemp -d)"; cp -R "mcp/$MCP_NAME/." "$T/"; rm -rf "$T/.git" "$T/.venv"
( cd "$T" && git init -qb "$MCP_BR" && git add -A \
  && git -c user.email=demo@local -c user.name=demo commit -qm "$MCP_NAME at root for Cloud Run" \
  && git remote add origin "$GITURL" && git push -fq origin "$MCP_BR" ) && ok "pushed $MCP_NAME -> ${SLUG}@${MCP_BR} (root)"
rm -rf "$T"

step "Deploying the MCP tool '$MCP_NAME' to Cloud Run ($MCP_DEPLOY)"
reset_deployment "$MCP_DEPLOY"
arctl apply -f - <<EOF
apiVersion: ar.dev/v1alpha1
kind: Deployment
metadata: {name: ${MCP_DEPLOY}}
spec:
  targetRef:  {kind: MCPServer, name: ${MCP_NAME}}
  runtimeRef: {kind: Runtime,   name: ${GCP_RUNTIME_ID}}
  runtimeConfig:
    gitRepoUrl: "${GITURL}"
    gitBranch: ${MCP_BR}
    useDockerfile: true
    allowUnauthenticated: true
EOF

step "Waiting for the MCP to be Ready on Cloud Run (the agent links to it)"
ph=""
for i in $(seq 1 45); do
  ph="$(arctl get deployment "$MCP_DEPLOY" -o yaml 2>/dev/null | awk '/^  phase:/{print $2; exit}')"
  case "$ph" in
    ready|active|deployed|succeeded|running) ok "MCP '$MCP_DEPLOY' is $ph"; break ;;
    failed|error) die "MCP '$MCP_DEPLOY' deploy $ph — see: arctl get deployment $MCP_DEPLOY -o yaml" ;;
    *) log "MCP '$MCP_DEPLOY': ${ph:-pending} [$i/45]"; sleep 20 ;;
  esac
done

step "Deploying the agent '$AGENT' to Vertex AI Agent Engine ($AGENT_DEPLOY)"
# Source comes from git (Cloud Build); the agent's MCP tools are linked via
# deploymentRefs -> the Cloud Run MCP deployment above.
reset_deployment "$AGENT_DEPLOY"
arctl apply -f - <<EOF
apiVersion: ar.dev/v1alpha1
kind: Deployment
metadata: {name: ${AGENT_DEPLOY}}
spec:
  targetRef: {kind: Agent, name: ${AGENT}}
  runtimeRef: {kind: Runtime, name: ${GCP_RUNTIME_ID}}
  deploymentRefs:
    - name: ${MCP_DEPLOY}
  runtimeConfig:
    gitRepoUrl: "${GITURL}"
    gitBranch: ${AGENT_BR}
    workdir: ${AGENT}
    displayName: ${AGENT}
  env:
    MODEL_PROVIDER: anthropic
    ANTHROPIC_API_KEY: "${ANTHROPIC_API_KEY}"
EOF
ok "agent deploy submitted — Vertex AI Agent Engine provisions in the background (~5-10 min)."
log "Watch it:  arctl get deployments    ·    invoke when READY:  ./scripts/gcp-invoke.sh"
