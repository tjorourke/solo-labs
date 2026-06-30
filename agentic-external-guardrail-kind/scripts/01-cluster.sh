#!/usr/bin/env bash
# 01-cluster.sh — kind cluster + MetalLB + Gateway API CRDs.
#
# Identical to agentic-pii-guardrail-kind/scripts/01-cluster.sh (Part 1). Part 2
# reuses the same cluster bring-up so the two labs are interchangeable at the
# infra layer. Idempotent on every step.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

step "Pre-flight"
require kind
require kubectl
require helm
require docker
check_docker
ok "tools + docker reachable"

# ── kind cluster ──────────────────────────────────────────────────────────────
step "Creating kind cluster '$CLUSTER_NAME'"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  ok "cluster '$CLUSTER_NAME' already exists — skipping"
else
  kind create cluster --config "$LAB_ROOT/kind/cluster.yaml"
  ok "cluster '$CLUSTER_NAME' created"
fi

# ── MetalLB ───────────────────────────────────────────────────────────────────
step "Installing MetalLB $METALLB_VERSION"
kc apply -f \
  "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml" \
  >/dev/null
ok "MetalLB manifests applied"

log "waiting for MetalLB controller..."
kc -n metallb-system wait \
  --for=condition=Ready pod -l app=metallb,component=controller --timeout=120s >/dev/null
ok "MetalLB controller ready"

KIND_CIDR="$(docker network inspect kind \
  --format '{{range .IPAM.Config}}{{println .Subnet}}{{end}}' 2>/dev/null \
  | grep -v ':' | head -1)"
[[ -n "$KIND_CIDR" ]] || die "kind docker network not found"
BASE="$(echo "$KIND_CIDR" | cut -d. -f1,2)"
log "kind network: $KIND_CIDR (base: $BASE)"

kc apply -f - >/dev/null <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata: { name: kind-pool, namespace: metallb-system }
spec:
  addresses: ["${BASE}.255.200-${BASE}.255.220"]
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata: { name: kind-l2, namespace: metallb-system }
EOF
ok "MetalLB pool: ${BASE}.255.200-${BASE}.255.220"

# ── Gateway API CRDs ──────────────────────────────────────────────────────────
step "Installing Gateway API CRDs $GATEWAY_API_VERSION"
kc apply -f \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" \
  >/dev/null
ok "Gateway API CRDs applied"

step "Cluster ready"
echo "  Context: $CTX" >&2
echo "  Next:    ./scripts/02-agentgateway.sh" >&2
