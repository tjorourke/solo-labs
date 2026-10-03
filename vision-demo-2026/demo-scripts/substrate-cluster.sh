#!/usr/bin/env bash
# substrate-cluster.sh — enable kagent Agent Substrate (gVisor) on mesh2 for Parts 5 and 12.
# Substrate used to have a kind cluster of its own. mesh2 carries only the second half of
# the ambient demos, so it has the room, and that saves a third cluster. mesh2 comes from
# setup.sh; this script does not create it. Idempotent: re-runs upgrade in place.
#
#   ./demo-scripts/substrate-cluster.sh
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CTX="${SUBSTRATE_CTX:-kind-mesh2}"
if ! kubectl config get-contexts -o name 2>/dev/null | grep -qx "$CTX"; then
  echo "✗ no $CTX context. Build mesh1 and mesh2 first: ./demo-scripts/setup.sh" >&2
  exit 1
fi
SUBSTRATE_CTX="$CTX" bash "$SCRIPT_DIR/substrate-up.sh"
echo "✔ Agent Substrate ready on $CTX. Demo it in demo-5-substrate.ipynb or demo-12-agent-substrate.ipynb."
