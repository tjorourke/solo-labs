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
export GCP_LOG="${TMPDIR:-/tmp}/gcp-deploy.log"
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.arctl/bin:$PATH"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh" >/dev/null 2>&1
arctl_login >/dev/null 2>&1

GCP_RUNTIME_ID="${GCP_RUNTIME_ID:-gcp-vertex}"
if ! arctl get runtime "$GCP_RUNTIME_ID" >/dev/null 2>&1; then
  echo "  Google platform '$GCP_RUNTIME_ID' is not connected. Run it once:"
  echo "    GCP_PROJECT_ID=<project> GCP_SA_KEY_FILE=<sa-key.json> ./scripts/04e-connect-gcp.sh"
  return 1 2>/dev/null || exit 1
fi
printf '✓ Google platform %s connected.\n' "$GCP_RUNTIME_ID"

printf '→ Deploying the MCP to Cloud Run + the agent to Vertex AI in the BACKGROUND — carry on with the kagent steps.\n'
nohup bash "$SCRIPT_DIR/gcp-deploy.sh" >"$GCP_LOG" 2>&1 &
printf '   started (PID %s) · watch it: tail -f %s\n' "$!" "$GCP_LOG"
printf '   §8b (./scripts/gcp-invoke.sh) waits for the agent to be READY, so just run it when you get there.\n'
