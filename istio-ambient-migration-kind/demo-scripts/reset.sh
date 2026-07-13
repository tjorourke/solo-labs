#!/usr/bin/env bash
# reset.sh — delete the kind cluster. Full teardown; re-run scripts/01-cluster.sh
# to rebuild.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../scripts/lib.sh"

step "Deleting kind cluster '$CLUSTER_NAME'"
kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 && ok "cluster deleted" || warn "no such cluster"
