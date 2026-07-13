#!/usr/bin/env bash
# 06-solo-interop.sh — the Solo-only capability. In-mesh sidecar callers already
# route through the waypoint automatically (ENABLE_WAYPOINT_INTEROP, default true
# on the Solo images). The Istio INGRESS gateway needs one explicit label to do
# the same: istio.io/ingress-use-waypoint=true on the target Service. Applying it
# makes north-south traffic flow through the waypoint, so the waypoint's L7 authz
# and the canary apply to ingress traffic too.
#
# Optional last step: the from-waypoint L4 lockdown that forces ALL traffic
# through the waypoint. Run with LOCKDOWN=1 to apply it (only after the ingress
# label above — see the ordering note in the manifest).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

step "Routing the Istio ingress gateway through the waypoint"
# yaml/60 sets both istio.io/use-waypoint and istio.io/ingress-use-waypoint.
kapply "$LAB_ROOT/yaml/60-solo-sidecar-waypoint/catalog-use-waypoint.yaml"
ok "catalog Service labelled istio.io/ingress-use-waypoint=true"
log "ingress traffic now hits the waypoint — try a DELETE through the ingress: it 403s."

if [[ "${LOCKDOWN:-0}" == "1" ]]; then
  step "Hardening: lock catalog pods to the waypoint identity (L7 cannot be bypassed)"
  kapply "$LAB_ROOT/yaml/40-policies-waypoint/20-catalog-from-waypoint-l4.yaml"
  ok "from-waypoint L4 policy applied — direct pod-IP access is now denied"
fi

echo
ok "Mixed fleet is safe: sidecar + ingress callers are enforced by the waypoint's L7 policy."
log "next: ./scripts/07-httproute.sh"
