#!/usr/bin/env bash
# svid.sh — show that a workload's identity IS its certificate.
#
# ztunnel holds an mTLS SVID per workload identity. This prints the workloads
# ztunnel knows in the petshop namespace, then the SPIFFE identities on the
# certificates it presents on their behalf. The URI SAN you see
# (spiffe://cert-identity/ns/petshop/sa/<sa>) is exactly what an L4
# AuthorizationPolicy 'principals' field matches on.
#
# Watch for the gap: checkout-blue and checkout-green share sa/checkout, so
# ztunnel holds ONE cert for the two pods — the L4 identity cannot tell them apart.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

step "Workloads ztunnel knows in $NS_APP (name, node, protocol)"
ic ztunnel-config workload 2>/dev/null | grep -E "NAMESPACE|$NS_APP"

# The 'certificate' subcommand reports per-ztunnel, so target the ztunnel on a
# node that actually has app pods.
NODE="$(kc -n "$NS_APP" get pods -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)"
ZT="$(kc -n "$ISTIO_SYSTEM_NS" get pods -l app=ztunnel --field-selector "spec.nodeName=${NODE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
[[ -n "$ZT" ]] || die "could not find a ztunnel pod on node '$NODE'"

step "SPIFFE SVIDs ztunnel '$ZT' holds (leaf certs, $NS_APP)"
ic ztunnel-config certificate "$ZT.$ISTIO_SYSTEM_NS" 2>/dev/null \
  | grep -E "CERTIFICATE NAME|$NS_APP" | grep -Ei "name|leaf" \
  || ic ztunnel-config certificate "$ZT.$ISTIO_SYSTEM_NS" 2>/dev/null | grep "$NS_APP"

echo
log "The identity on the cert is the ServiceAccount. Note that checkout-blue and"
log "checkout-green resolve to the SAME SVID (…/sa/checkout) — that is the gap the"
log "workload-claims step (make claims-enable && make claims) closes."
