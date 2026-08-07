#!/usr/bin/env bash
# substrate-cluster.sh — create the dedicated kind-substrate cluster and enable kagent
# Agent Substrate (gVisor) on it. Part 5 runs here, isolated from mesh1 (which stays on
# kagent v0.4.3 for Part 4). Idempotent: re-runs skip an existing cluster and upgrade.
#
#   ./demo-scripts/substrate-cluster.sh
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
if ! kind get clusters 2>/dev/null | grep -qx substrate; then
  echo "→ creating kind cluster 'substrate' ..."
  kind create cluster --config "$SCRIPT_DIR/kind/substrate.yaml"
else
  echo "→ kind cluster 'substrate' already exists"
fi
CTX=kind-substrate bash "$SCRIPT_DIR/substrate-up.sh"
echo "✔ Part 5 substrate cluster ready (context kind-substrate). Demo it in demo-5-substrate.ipynb."
