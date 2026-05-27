#!/usr/bin/env bash
# Step 1 — create east-ag + west-ag kind clusters.
# Usage: CLUSTER1=kind-east-ag CLUSTER2=kind-west-ag ./scripts/01-clusters.sh

set -Eeuo pipefail

CLUSTER1="${CLUSTER1:-kind-east-ag}"
CLUSTER2="${CLUSTER2:-kind-west-ag}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

require() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: $1 not found — install it first"; exit 1; }; }
require kind
require kubectl

# Strip "kind-" prefix to get the cluster name for the config file.
cluster_name() { echo "${1#kind-}"; }

create_cluster() {
  local ctx="$1"
  local name; name="$(cluster_name "$ctx")"
  local cfg="$REPO_ROOT/kind/${name}.yaml"

  if kind get clusters 2>/dev/null | grep -q "^${name}$"; then
    echo "  [$name] already exists — skipping"
    return
  fi

  if [[ ! -f "$cfg" ]]; then
    echo "ERROR: kind config not found: $cfg"; exit 1
  fi

  echo "  [$name] creating..."
  kind create cluster --config "$cfg"
  echo "  [$name] created"
}

echo "==> Creating kind clusters"
create_cluster "$CLUSTER1"
create_cluster "$CLUSTER2"

echo ""
echo "Contexts available:"
kubectl config get-contexts | grep -E "east|west" || true

echo ""
echo "Next: ./scripts/02-metallb.sh"
