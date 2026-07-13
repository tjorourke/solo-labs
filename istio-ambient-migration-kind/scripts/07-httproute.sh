#!/usr/bin/env bash
# 07-httproute.sh — modernize the canary from DestinationRule subsets +
# VirtualService to per-version Services + a Gateway-API HTTPRoute. Clients keep
# addressing the original catalog hostname; the HTTPRoute (enforced at the
# waypoint) does the weighted split, which is the knob Argo Rollouts drives.
# Zero-downtime: the HTTPRoute starts 100% v1, matching the VS it replaces.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

step "1) Per-version Services + HTTPRoute (still 100% v1)"
kapply "$LAB_ROOT/yaml/50-httproute/10-versioned-services.yaml"
kapply "$LAB_ROOT/yaml/50-httproute/20-catalog-httproute.yaml"
ok "catalog-v1 / catalog-v2 Services + HTTPRoute applied"

step "2) Retire the VirtualService; keep DestinationRule traffic policy (subsets removed)"
kc -n "$NS_APP" delete virtualservice catalog --ignore-not-found >/dev/null
kapply "$LAB_ROOT/yaml/50-httproute/30-catalog-dr-nosubset.yaml"
ok "VirtualService deleted; subset-less DestinationRule in place"

kc -n "$NS_APP" get httproute,virtualservice,destinationrule 2>/dev/null

echo
ok "Canary now runs on the HTTPRoute. Shift traffic by editing backendRef weights:"
log "  kubectl -n $NS_APP patch httproute catalog --type=json -p='[{\"op\":\"replace\",\"path\":\"/spec/rules/0/backendRefs/1/weight\",\"value\":50}]'"
log "next (optional): ./scripts/rollback.sh $NS_DATA"
