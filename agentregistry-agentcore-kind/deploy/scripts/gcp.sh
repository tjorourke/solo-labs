#!/usr/bin/env bash
# gcp.sh — SOURCE it:  source scripts/gcp.sh
#
# Kicks off the Google Cloud deploy (runtime 3) with a fast-returning cell so the
# notebook doesn't queue your other steps:
#   • FOREGROUND (~5s): confirm the GeminiAgentRuntime platform is connected.
#   • BACKGROUND: the slow part — push the MCP source, deploy it to Cloud Run, wait
#     for it to be Ready, then deploy the agent to Vertex AI Agent Engine. Runs
#     detached (~8-12 min total) while you carry on with the kagent steps.
#
# Unlike kagent, Google needs the MCP on Cloud Run BEFORE the agent (the agent
# links to it via deploymentRefs), so the whole sequence is backgrounded together.
# §8b (./scripts/gcp-invoke.sh) waits for the agent to be READY, so just run it
# when you get there.
#
# Watch the background deploy any time:  tail -f $GCP_LOG
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export GCP_LOG="${TMPDIR:-/tmp}/gcp-deploy.log"
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.arctl/bin:$PATH"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh" >/dev/null 2>&1
load_secrets >/dev/null 2>&1 || true   # GCP_PROJECT_ID / GCP_SA_KEY_FILE from .env.local
arctl_login >/dev/null 2>&1

GCP_RUNTIME_ID="${GCP_RUNTIME_ID:-gcp-vertex}"
# Self-sufficient like §5/AWS: if the Google runtime isn't connected yet, connect it
# inline here (bootstrap the deployer SA + key on first run, then register it),
# rather than bailing. Needs GCP_PROJECT_ID (./scripts/setup-env.sh) and an
# authenticated gcloud CLI. Force-skip Google with CONNECT_GCP=false.
if [ "${CONNECT_GCP:-}" = "false" ]; then
  echo "  CONNECT_GCP=false — skipping Google."; return 0 2>/dev/null || exit 0
fi
if ! arctl get runtime "$GCP_RUNTIME_ID" >/dev/null 2>&1; then
  if [ -z "${GCP_PROJECT_ID:-}" ]; then
    echo "  Google not configured — set GCP_PROJECT_ID in .env.local (./scripts/setup-env.sh), then re-run this cell."
    return 1 2>/dev/null || exit 1
  fi
  # Normalise the key path to absolute so the bootstrap and the connect agree on it.
  GCP_SA_KEY_FILE="${GCP_SA_KEY_FILE:-.agentcore/sa-gcp-deployer.json}"
  case "$GCP_SA_KEY_FILE" in /*) ;; *) GCP_SA_KEY_FILE="$LAB_ROOT/$GCP_SA_KEY_FILE";; esac
  export GCP_SA_KEY_FILE GCP_PROJECT_ID
  if [ ! -r "$GCP_SA_KEY_FILE" ]; then
    echo "→ First run: creating the GCP deployer service account + key (arctl runtime setup)…"
    mkdir -p "$(dirname "$GCP_SA_KEY_FILE")"
    arctl runtime setup gemini-agent-runtime --project-id "$GCP_PROJECT_ID" --key-file "$GCP_SA_KEY_FILE" >&2 \
      || { echo "  GCP bootstrap failed — is the gcloud CLI authenticated for ${GCP_PROJECT_ID}? (gcloud auth login)"; return 1 2>/dev/null || exit 1; }
  fi
  echo "→ Connecting the Google platform (${GCP_RUNTIME_ID})…"
  bash "$SCRIPT_DIR/04e-connect-gcp.sh" >&2 \
    || { echo "  connecting ${GCP_RUNTIME_ID} failed — see output above."; return 1 2>/dev/null || exit 1; }
fi
arctl get runtime "$GCP_RUNTIME_ID" >/dev/null 2>&1 \
  || { echo "  ${GCP_RUNTIME_ID} still not connected."; return 1 2>/dev/null || exit 1; }
printf '✓ Google platform %s connected.\n' "$GCP_RUNTIME_ID"

printf '→ Deploying the MCP to Cloud Run + the agent to Vertex AI in the BACKGROUND — carry on with the kagent steps.\n'
nohup bash "$SCRIPT_DIR/gcp-deploy.sh" >"$GCP_LOG" 2>&1 &
printf '   started (PID %s) · watch it: tail -f %s\n' "$!" "$GCP_LOG"
printf '   §8b (./scripts/gcp-invoke.sh) waits for the agent to be READY, so just run it when you get there.\n'
