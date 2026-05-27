#!/usr/bin/env bash
# Create kind clusters using CLUSTER1 and CLUSTER2 env vars.
# Ref: https://github.com/rvennam/ambient-multicluster-workshop
#
# CLUSTER1 and CLUSTER2 are kubectl context names (e.g. kind-east, kind-west).
# The kind cluster name is the context name with the "kind-" prefix stripped.
#
# Distinct pod/service CIDRs prevent cross-cluster routing conflicts:
#   east: pods 10.10.0.0/16  services 10.96.0.0/16
#   west: pods 10.20.0.0/16  services 10.97.0.0/16

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CLUSTER1="${CLUSTER1:-kind-east-istio}"
CLUSTER2="${CLUSTER2:-kind-west-istio}"

log()    { echo "  → $*"; }
log_ok() { echo "  ✓ $*"; }
die()    { echo "ERROR: $*" >&2; exit 1; }

command -v kind    >/dev/null || die "kind not installed — brew install kind"
command -v kubectl >/dev/null || die "kubectl not installed — brew install kubectl"

for ctx in "$CLUSTER1" "$CLUSTER2"; do
  cluster="${ctx#kind-}"   # strip "kind-" prefix → cluster name used by kind
  config="$REPO_ROOT/kind/${cluster}.yaml"
  [[ -f "$config" ]] || die "no kind config for cluster '$cluster' at $config"

  if kind get clusters 2>/dev/null | grep -qx "$cluster"; then
    log_ok "cluster '$cluster' already exists — skipping"
  else
    log "creating cluster '$cluster'..."
    kind create cluster --config "$config"
    log_ok "cluster '$cluster' ready"
  fi
done

echo
echo "Contexts:"
kubectl config get-contexts 2>/dev/null | grep -E "${CLUSTER1}|${CLUSTER2}" || true
echo
echo "Next: ./scripts/02-metallb.sh"
