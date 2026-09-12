#!/usr/bin/env bash
# Verify that an identically named service account in another namespace has no grant.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../agent-authoring-contract-kind/scripts/lib.sh
source "$SCRIPT_DIR/../../agent-authoring-contract-kind/scripts/lib.sh"
TARGET_NS="$NS"
PROBE_NS="containment-probe-$RANDOM-$RANDOM"
kc create namespace "$PROBE_NS" >/dev/null
trap 'kc delete namespace "$PROBE_NS" --wait=true --timeout=120s >/dev/null || warn "remove namespace $PROBE_NS after the failed cleanup"' EXIT
kc label namespace "$PROBE_NS" istio.io/dataplane-mode=ambient >/dev/null
kc -n "$PROBE_NS" create serviceaccount sre-contained >/dev/null
printf 'Same service-account name, different namespace: %s/sre-contained\n' "$PROBE_NS"
NS="$PROBE_NS" bash "$SCRIPT_DIR/probe-as.sh" sre-contained "http://contained-tools.$TARGET_NS.svc.cluster.local/mcp"
