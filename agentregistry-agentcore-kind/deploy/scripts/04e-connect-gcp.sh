#!/usr/bin/env bash
# 04e-connect-gcp.sh — register the Google Cloud platform as a GeminiAgentRuntime
# on the in-cluster AgentRegistry, so the AR UI renders it under Runtimes
# alongside kind-kagent and aws-agentcore. Mirrors 04b-register-runtime.sh and
# 04d-connect-aws.sh.
#
# This step ONLY registers the connected platform so it shows up — it does NOT
# run the gcloud bootstrap (service account + IAM) or deploy any agent/MCP to it.
# A GeminiAgentRuntime deploys agents to Vertex AI and MCP servers to Cloud Run;
# wiring a real deploy is a later step. To make this runtime actually deployable,
# run `arctl runtime setup gemini-agent-runtime --project-id <PROJECT>` and set
# GCP_SA_KEY_FILE below to the generated sa-gcp-deployer.json.
#
# Registering needs only projectId — location defaults to us-central1 and the
# service-account key is optional and not validated at apply time, so the runtime
# row is created and visible without any live GCP access.
#
# GCP is opt-in and independent of AWS: it connects only when you set GCP_PROJECT_ID
# (and, to make it deployable, GCP_SA_KEY_FILE). With neither set it skips, so the
# lab runs kagent-only or kagent+AWS unchanged. Force-skip with CONNECT_GCP=false.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
load_secrets   # pull GCP_PROJECT_ID / GCP_SA_KEY_FILE from .env.local when run via setup.sh

if [[ "${CONNECT_GCP:-}" == "false" ]]; then
  log "CONNECT_GCP=false — skipping the Google Cloud GeminiAgentRuntime platform"; exit 0
fi

# ── config (override via env) ────────────────────────────────────────────────
GCP_RUNTIME_ID="${GCP_RUNTIME_ID:-gcp-vertex}"
GCP_PROJECT_ID="${GCP_PROJECT_ID:-}"                   # set this to connect Google; unset = skip
GCP_LOCATION="${GCP_LOCATION:-us-central1}"            # Vertex AI / Cloud Run region
GCP_SA_KEY_FILE="${GCP_SA_KEY_FILE:-}"                 # optional: sa-gcp-deployer.json from `arctl runtime setup`

# Google is opt-in and independent of AWS. Skip cleanly unless you point it at a
# project (mirrors 04d-connect-aws.sh, which skips when there's no AWS session).
if [[ -z "$GCP_PROJECT_ID" ]]; then
  log "no GCP_PROJECT_ID — skipping the Google Vertex runtime (kagent + any AWS runtime still work)."
  log "  to connect it:  arctl runtime setup gemini-agent-runtime --project-id <project>   then"
  log "                  GCP_PROJECT_ID=<project> GCP_SA_KEY_FILE=sa-gcp-deployer.json ./scripts/04e-connect-gcp.sh"
  exit 0
fi

step "Connecting the Google Cloud platform (GeminiAgentRuntime '${GCP_RUNTIME_ID}', project ${GCP_PROJECT_ID})"
arctl_login

# Build the runtime manifest. serviceAccountKey is only inlined when a key file
# is provided; without it the runtime registers as visible-but-not-yet-deployable.
RT="$(mktemp)"
{
  cat <<EOF
apiVersion: ar.dev/v1alpha1
kind: Runtime
metadata:
  name: ${GCP_RUNTIME_ID}
spec:
  type: GeminiAgentRuntime
  telemetryEndpoint: ${AR_TELEMETRY_ENDPOINT}
  config:
    projectId: "${GCP_PROJECT_ID}"
    location: "${GCP_LOCATION}"
EOF
  if [[ -n "$GCP_SA_KEY_FILE" && -r "$GCP_SA_KEY_FILE" ]]; then
    echo "    serviceAccountKey: |"
    sed 's/^/      /' "$GCP_SA_KEY_FILE"
  fi
} > "$RT"

if [[ -n "$GCP_SA_KEY_FILE" && -r "$GCP_SA_KEY_FILE" ]]; then
  ok "inlining service-account key from ${GCP_SA_KEY_FILE} (deployable runtime)"
else
  log "no GCP_SA_KEY_FILE — registering a visible runtime only (not yet deployable)"
fi

arctl apply -f "$RT"; rm -f "$RT"

step "Verifying the Google Cloud platform is registered"
arctl get runtime "$GCP_RUNTIME_ID" >/dev/null 2>&1 || die "${GCP_RUNTIME_ID} runtime not registered"
ok "GCP platform '${GCP_RUNTIME_ID}' registered (GeminiAgentRuntime)"
arctl get runtimes 2>/dev/null | sed 's/^/  /' >&2 || true
