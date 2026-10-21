#!/usr/bin/env bash
# 99-teardown.sh: delete the kind cluster. Nothing was installed outside it
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
# Read the state back rather than trusting the exit code of kind delete.
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  die "cluster '$CLUSTER_NAME' still exists"
fi
left="$(docker ps -a --filter "label=io.x-k8s.kind.cluster=$CLUSTER_NAME" -q | wc -l | tr -d ' ')"
[[ "$left" == 0 ]] || die "$left kind node container(s) for '$CLUSTER_NAME' still exist"
if kubectl config get-contexts -o name 2>/dev/null | grep -qx "$CTX"; then
  die "kubeconfig context $CTX still exists"
fi
ok "gone: no cluster, no node containers, no kubeconfig context"
