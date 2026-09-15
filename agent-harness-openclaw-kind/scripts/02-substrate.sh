#!/usr/bin/env bash
# 02-substrate.sh — install Agent Substrate (CRDs, control plane, data plane) into ate-system.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

step "Agent Substrate ${SUBSTRATE_VERSION}"
helm --kube-context "$CTX" upgrade --install substrate-crds \
  oci://ghcr.io/kagent-dev/substrate/helm/substrate-crds \
  --version "$SUBSTRATE_VERSION" --namespace "$ATE_NS" --create-namespace --wait >/dev/null
helm_install_with_progress substrate oci://ghcr.io/kagent-dev/substrate/helm/substrate "$ATE_NS" \
  --version "$SUBSTRATE_VERSION" --wait --timeout 15m

step "Substrate control plane"
kc -n "$ATE_NS" rollout status deploy/ate-api-server-deployment --timeout=300s >/dev/null
kc -n "$ATE_NS" rollout status deploy/ate-controller --timeout=300s >/dev/null
kc -n "$ATE_NS" rollout status deploy/atenet-router --timeout=300s >/dev/null
kc -n "$ATE_NS" rollout status ds/atelet --timeout=300s >/dev/null
# Pod readiness is not cluster health for Valkey: after a restart with retained PVCs the
# nodes can be Running while gossip still points at old pod addresses. Check the cluster.
for _ in $(seq 1 30); do
  if kc -n "$ATE_NS" exec valkey-cluster-0 -- valkey-cli CLUSTER INFO 2>/dev/null | tr -d '\r' | grep -qx 'cluster_state:ok'; then
    break
  fi
  sleep 5
done
kc -n "$ATE_NS" exec valkey-cluster-0 -- valkey-cli CLUSTER INFO 2>/dev/null | tr -d '\r' | grep -qx 'cluster_state:ok' \
  || die "Valkey cluster_state is not ok; see spikes/version-contract.md for the retained-state case"
kc -n "$ATE_NS" get pods
ok "Substrate control plane healthy in ${ATE_NS}"
