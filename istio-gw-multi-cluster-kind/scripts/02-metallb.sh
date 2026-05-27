#!/usr/bin/env bash
# Install MetalLB on both clusters and configure non-overlapping IP pools.
# Reads CLUSTER1 / CLUSTER2 env vars (default: kind-east / kind-west).
# Replaces cloud-provider-kind, which has a known macOS bug where it fails to
# write the assigned IP back to status.loadBalancer.ingress.
#
# IP pool ranges are derived at runtime from the 'kind' Docker network CIDR —
# they are NOT hardcoded, since Docker's IPAM assigns a different /16 on each
# machine depending on what other networks exist.
#
# Layout (example if kind network is 172.22.0.0/16):
#   nodes:         <base>.0.2 - <base>.0.9   (kind-assigned)
#   CLUSTER1 pool: <base>.255.200 - <base>.255.210
#   CLUSTER2 pool: <base>.255.220 - <base>.255.230

set -Eeuo pipefail

log()    { echo "  → $*"; }
log_ok() { echo "  ✓ $*"; }
die()    { echo "ERROR: $*" >&2; exit 1; }

[[ -n "${CLUSTER1:-}" ]] || die "CLUSTER1 is not set — run: export CLUSTER1=kind-east"
[[ -n "${CLUSTER2:-}" ]] || die "CLUSTER2 is not set — run: export CLUSTER2=kind-west"

METALLB_VERSION="v0.14.9"
METALLB_URL="https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml"

# ── Detect kind network CIDR ──────────────────────────────────────────────────
log "detecting kind network CIDR..."
KIND_CIDR=$(docker network inspect kind \
  --format '{{range .IPAM.Config}}{{if .Subnet}}{{println .Subnet}}{{end}}{{end}}' 2>/dev/null \
  | grep -v ':' | head -1 || true)

[[ -n "$KIND_CIDR" ]] || die "Could not detect kind network CIDR — is the kind network up? Run scripts/01-clusters.sh first."

# Extract the first two octets (handles /16 like 172.22.0.0/16 → 172.22)
BASE=$(echo "$KIND_CIDR" | cut -d. -f1-2)

POOL1_RANGE="${BASE}.255.200-${BASE}.255.210"
POOL2_RANGE="${BASE}.255.220-${BASE}.255.230"

log_ok "kind network: ${KIND_CIDR}"
log_ok "${CLUSTER1} pool: ${POOL1_RANGE}"
log_ok "${CLUSTER2} pool: ${POOL2_RANGE}"

# ── Install MetalLB ───────────────────────────────────────────────────────────
log "installing MetalLB ${METALLB_VERSION} on ${CLUSTER1}..."
kubectl --context="${CLUSTER1}" apply -f "$METALLB_URL"
log_ok "MetalLB installed on ${CLUSTER1}"

log "installing MetalLB ${METALLB_VERSION} on ${CLUSTER2}..."
kubectl --context="${CLUSTER2}" apply -f "$METALLB_URL"
log_ok "MetalLB installed on ${CLUSTER2}"

log "waiting for MetalLB controller on ${CLUSTER1}..."
kubectl --context="${CLUSTER1}" -n metallb-system wait \
  --for=condition=ready pod --selector=component=controller --timeout=120s
log_ok "controller ready on ${CLUSTER1}"

log "waiting for MetalLB controller on ${CLUSTER2}..."
kubectl --context="${CLUSTER2}" -n metallb-system wait \
  --for=condition=ready pod --selector=component=controller --timeout=120s
log_ok "controller ready on ${CLUSTER2}"

# ── Apply IP pools (generated from kind network CIDR) ────────────────────────
log "applying IP pools"

kubectl --context="${CLUSTER1}" apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: kind-pool
  namespace: metallb-system
spec:
  addresses:
  - ${POOL1_RANGE}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: kind-l2
  namespace: metallb-system
EOF

kubectl --context="${CLUSTER2}" apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: kind-pool
  namespace: metallb-system
spec:
  addresses:
  - ${POOL2_RANGE}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: kind-l2
  namespace: metallb-system
EOF

log_ok "pools applied"

sleep 5

echo
echo "LoadBalancer services:"
kubectl --context="${CLUSTER1}" get svc -A --field-selector spec.type=LoadBalancer \
  --no-headers 2>/dev/null | awk -v c="${CLUSTER1}" '{printf "  %s  %-40s %s\n", c, $2, $5}'
kubectl --context="${CLUSTER2}" get svc -A --field-selector spec.type=LoadBalancer \
  --no-headers 2>/dev/null | awk -v c="${CLUSTER2}" '{printf "  %s  %-40s %s\n", c, $2, $5}'
