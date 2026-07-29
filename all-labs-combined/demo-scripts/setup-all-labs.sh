#!/usr/bin/env bash
# setup-all-labs.sh — stand up every cluster needed to run the 7-part demo suite.
#
#   Clusters:
#     mesh1 + mesh2   Parts 1-4, 7 + Cost Management (this dir's setup.sh + agentregistry/setup-mesh1.sh + ai-gateway.sh)
#     substrate       Part 5 (gVisor sandbox)       (demo-scripts/substrate-cluster.sh — kagent v0.5.2)
#     inference       Part 6 (InferencePool/GIE)    (../agentgateway-inference-routing-kind, non-mesh gateway)
#
# Needs SECRETS_FILE (SOLO_ISTIO_LICENSE_KEY, AGENTGATEWAY_LICENSE_KEY, ANTHROPIC_API_KEY).
# Skip parts you don't need: SKIP_MESH / SKIP_PART4 / SKIP_SUBSTRATE / SKIP_INFERENCE / SKIP_AIGW = true.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SECRETS_FILE="${SECRETS_FILE:-$HOME/code/solo/secrets/secrets-envs.sh}"

[[ "${SKIP_MESH:-false}"      == "true" ]] || { echo "==> mesh1 + mesh2 (Parts 1-3 + Cost)";  bash "$SCRIPT_DIR/setup.sh"; }
[[ "${SKIP_PART4:-false}"     == "true" ]] || { echo "==> AgentRegistry platform on mesh1 (Part 4)"; bash "$SCRIPT_DIR/agentregistry/setup-mesh1.sh"; }
[[ "${SKIP_SUBSTRATE:-false}" == "true" ]] || { echo "==> substrate cluster (Part 5)";      bash "$SCRIPT_DIR/substrate-cluster.sh"; }
[[ "${SKIP_INFERENCE:-false}" == "true" ]] || { echo "==> inference cluster (Part 6)";       ( cd "$LAB_ROOT/../agentgateway-inference-routing-kind" && bash scripts/quick.sh up ); }
[[ "${SKIP_AIGW:-false}"      == "true" ]] || { echo "==> AI gateway platform on mesh1 (Part 7)"; bash "$SCRIPT_DIR/ai-gateway.sh"; }

echo
echo "✔ clusters up: $(kind get clusters | tr '\n' ' ')"
