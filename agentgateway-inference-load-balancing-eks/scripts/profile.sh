#!/usr/bin/env bash
# Switch the Endpoint Picker's scheduling profile.
#
#   ./scripts/profile.sh              list the profiles
#   ./scripts/profile.sh default      the three weighted scorers the GIE chart ships
#   ./scripts/profile.sh queue-only   queue depth alone
#   ./scripts/profile.sh prefix-only  prefix affinity alone
#   ./scripts/profile.sh random       no scoring at all, the control
#
# Each profile is a Helm values file in epp-profiles/ holding a complete
# EndpointPickerConfig. Read them: they are short, and the whole scheduling algorithm is
# in there.
#
# The switch is a Helm upgrade, which rolls the EPP pod. That matters more than it
# looks: the prefix-cache-scorer's index lives in the EPP's memory, so a profile switch
# throws away everything it had learned about which replica holds which prefix. It is
# also the only honest way to run these comparisons, since an index warmed by the
# previous profile's traffic would flatter whichever profile ran second. The script
# waits for the new pod before returning.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

PROFILE="${1:-}"
if [ -z "$PROFILE" ]; then
  echo "profiles in $LAB_ROOT/epp-profiles:"
  for f in "$LAB_ROOT"/epp-profiles/*.yaml; do
    b="$(basename "$f" .yaml)"
    [ "$b" = "base" ] && continue
    printf '  %-14s %s\n' "$b" "$(sed -n '1s/^# //p' "$f")"
  done
  exit 0
fi

VALUES="$LAB_ROOT/epp-profiles/${PROFILE}.yaml"
[ -f "$VALUES" ] || die "no such profile: $PROFILE (try: $0)"

resolve_ctx

helm_ upgrade --install "$POOL_RELEASE" "$GIE_POOL_CHART" \
  --version "$GIE_VERSION" \
  --namespace "$NS" --create-namespace \
  -f "$LAB_ROOT/epp-profiles/base.yaml" \
  -f "$VALUES" \
  --wait --timeout 5m >/dev/null

# rollout status, not just helm --wait: --wait is satisfied by the Deployment reporting
# available, which an old replica can do while the new config is still rolling.
kc -n "$NS" rollout status "deploy/${POOL_RELEASE}-epp" --timeout=180s >/dev/null

ok "Endpoint Picker running profile '$PROFILE'"
log "the config it loaded:"
kc -n "$NS" get configmap "${POOL_RELEASE}-epp" \
  -o jsonpath='{.data.custom-plugins\.yaml}' 2>/dev/null | sed 's/^/    /' >&2 || true
