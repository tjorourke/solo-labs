#!/usr/bin/env bash
# 99-teardown.sh — delete the kind cluster. Nothing in this lab is installed
# outside it.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

run kind delete cluster --name "$CLUSTER_NAME"
ok "cluster '$CLUSTER_NAME' deleted"
