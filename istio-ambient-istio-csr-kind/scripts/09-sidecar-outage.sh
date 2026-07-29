#!/usr/bin/env bash
# 09-sidecar-outage.sh — setting the Vault role to key_type=ec while sidecars
# still exist starts a sidecar outage.
#
# New and restarted sidecar pods are hit immediately: their RSA CSR bounces
# and the pod never becomes ready. Every EXISTING sidecar follows within one
# certificate TTL (1h in this lab), because its renewal CSR bounces the same
# way and the certificate it is serving with expires.
#
# What this does (controlled, one replica, then repaired):
#   - sets the role to key_type=ec
#   - scales ledger's httpbin to 2: the new replica's RSA CSR is rejected and
#     the pod sticks at not-ready — shown via the CertificateRequest
#   - sets the role back to key_type=any: the stuck replica recovers with no
#     other action, because the agent keeps retrying
#   - scales back to 1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
require jq

step "Lock the role to EC only (the mistake)"
"$SCRIPT_DIR/vault-pki.sh" role ec
"$SCRIPT_DIR/vault-pki.sh" show

step "Scale ledger's httpbin to 2 — the new sidecar needs an RSA cert"
run kubectl --context "$CTX" -n "$NS_STAY" scale deploy/httpbin --replicas=2

step "Vault rejects it: 'role requires keys of type ec'"
__deadline=$(( $(date +%s) + 180 ))
__cr=""
while [[ -z "$__cr" ]]; do
  __cr="$(kc -n "$ISTIO_SYSTEM_NS" get certificaterequests.cert-manager.io -o json \
    | jq -r '[.items[] | select(.status.conditions[]? | select(.type=="Ready" and .status=="False")
              | .message | test("keys of type ec"))] | last | .metadata.name // empty')"
  [[ -n "$__cr" ]] && break
  (( $(date +%s) > __deadline )) && die "no rejected CertificateRequest appeared within 180s"
  sleep 5
done
run kubectl --context "$CTX" -n "$ISTIO_SYSTEM_NS" get certificaterequest "$__cr" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}'
echo
run kubectl --context "$CTX" -n "$NS_STAY" get pods -l app=httpbin
log "the new replica is stuck. Every OTHER sidecar in the estate is on the same"
log "path: their 1h certs renew at ~30-45min, and every renewal will bounce too."

step "Repair: role back to key_type=any — the stuck replica heals itself"
"$SCRIPT_DIR/vault-pki.sh" role any
run kubectl --context "$CTX" -n "$NS_STAY" wait --for=condition=Available deploy/httpbin --timeout=240s
run kubectl --context "$CTX" -n "$NS_STAY" get pods -l app=httpbin
run kubectl --context "$CTX" -n "$NS_STAY" scale deploy/httpbin --replicas=1

ok "that is why the migration posture is key_type=any: the client picks the key type, the role just has to permit the mix you actually run."
