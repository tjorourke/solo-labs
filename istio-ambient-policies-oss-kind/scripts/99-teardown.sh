#!/usr/bin/env bash
# 99-teardown.sh — delete the kind cluster. Nothing was installed outside it
# except istioctl in .bin/, which is removed too.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

step "Deleting kind cluster '$CLUSTER_NAME'"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  show kind delete cluster --name "$CLUSTER_NAME"
else
  ok "cluster '$CLUSTER_NAME' not present"
fi
rm -rf "$LAB_BIN"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  die "cluster '$CLUSTER_NAME' still exists"
fi
ok "gone"
