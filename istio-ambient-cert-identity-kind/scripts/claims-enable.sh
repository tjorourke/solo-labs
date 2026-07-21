#!/usr/bin/env bash
# claims-enable.sh — turn on workload claims. This is the §13 step: one Helm
# value on ztunnel (ENABLE_WORKLOAD_CLAIMS=true) and ztunnel starts requesting
# a certificate PER POD (instead of one per ServiceAccount) with the pod's
# claims embedded — the raw material the CEL source.claims policy matches on.
#
# The flag stays OFF for the earlier sections on purpose: the shared-SA gap
# (blue and green on ONE cert) is the story this step then closes. Runs BEFORE
# the waypoint in the lab flow — workload claims is pure L4. The guarded
# deletes below only matter when re-running after the L7 sections.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require kubectl; require helm
require_secrets

step "Pure L4 stage (clear any L7 leftovers — no-ops on the first pass)"
kc -n "$NS_APP" delete enterpriseagentgatewaypolicy petshop-jwt petshop-authz petshop-ratelimit-storefront --ignore-not-found >/dev/null 2>&1 || true
kc label namespace "$NS_APP" istio.io/use-waypoint- >/dev/null 2>&1 || true
kc -n "$NS_APP" delete httproute petstore-split --ignore-not-found >/dev/null
kc -n "$NS_APP" delete gateway petshop-waypoint --ignore-not-found >/dev/null
ok "L7 objects removed; only L4 identity remains"

step "Helm: ztunnel with ENABLE_WORKLOAD_CLAIMS=true (same chart, one new value)"
helm --kube-context "$CTX" upgrade -i ztunnel "$ISTIO_HELM_REPO/ztunnel" \
  -n "$ISTIO_SYSTEM_NS" --version "$ISTIO_HELM_VERSION" --wait -f - >/dev/null <<EOF
profile: ambient
hub: ${ISTIO_REGISTRY}
tag: ${ISTIO_VERSION}
namespace: ${ISTIO_SYSTEM_NS}
istioNamespace: ${ISTIO_SYSTEM_NS}
env:
  LOG_FORMAT: json
  L7_ENABLED: "true"
  # per-POD certs (cache keyed by pod) + claims extraction/enforcement
  ENABLE_WORKLOAD_CLAIMS: "true"
EOF
kc -n "$ISTIO_SYSTEM_NS" rollout status daemonset/ztunnel --timeout=180s >/dev/null
ok "ztunnel rolled, workload claims ON — every workload now gets a per-pod cert"

echo
log "Next: make claims — annotate checkout blue/gold green/silver + apply the CEL policy."
