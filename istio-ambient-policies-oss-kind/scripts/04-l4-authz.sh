#!/usr/bin/env bash
# 04-l4-authz.sh: Policy 2: identity-based L4 authorization on catalog.
#
# A selector-based AuthorizationPolicy that only matches on the caller's mTLS
# principal. ztunnel enforces it on the node where catalog runs. reporting is
# refused at the connection, before any HTTP; checkout is unaffected.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require kubectl

step "Policy 2: AuthorizationPolicy catalog-l4 (ALLOW only the checkout identity)"
show kc apply -f "$LAB_ROOT/yaml/20-policies/20-l4-authz-catalog.yaml"
sleep 2

step "Probe"
"$SCRIPT_DIR/probe.sh" --no-jwt
log "reporting is reset, checkout's DELETE still succeeds: ztunnel cannot see the method."
log "Method, path and header rules need a waypoint. That is step 5."

step "Where it was enforced: ztunnel on catalog's node"
catalog_pod="$(kc -n "$NS_SHOP" get pod -l app=catalog -o jsonpath='{.items[0].metadata.name}')"
zt="$(ztunnel_for "$NS_SHOP" "$catalog_pod")"
show ic ztunnel-config policies --policy-namespace "$NS_SHOP"
log "the deny, as ztunnel logged it:"
kc -n "$ISTIO_SYSTEM_NS" logs "$zt" --since=1m 2>/dev/null \
  | grep '"src.workload":"reporting' | grep '"direction":"inbound"' | grep 'policy rejection' | tail -1 \
  | python3 -c 'import sys,json
for l in sys.stdin:
    try: d=json.loads(l)
    except Exception: print("   ", l.strip()); continue
    for k in ("src.identity","dst.identity","direction","error"):
        print(f"    {k:14} {d.get(k)}")' || true

echo
ok "Policy 2 in place: one identity may reach catalog, and the decision is made per connection."
log "Next: ./scripts/05-waypoint.sh"
