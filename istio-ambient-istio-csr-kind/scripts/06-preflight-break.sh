#!/usr/bin/env bash
# 06-preflight-break.sh — the first ambient enrolment, somewhere safe. This
# step is SUPPOSED to fail: that is the point of it.
#
# What this does:
#   - creates the preflight namespace, born straight into ambient
#     (istio.io/dataplane-mode=ambient on the namespace), with one httpbin pod
#   - the moment the pod starts, ztunnel requests a certificate for it — and
#     ztunnel can only generate ECDSA P-256 keys, while the Vault role still
#     says key_type=rsa
#   - shows the rejection, twice over: the preserved CertificateRequest with
#     Vault's exact error, and ztunnel's own log
#
# This is the dev-cluster rehearsal that saves the production estate: if you
# had enrolled a real namespace first, THIS is what would have happened to it.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
require jq

step "Current Vault role posture"
"$SCRIPT_DIR/vault-pki.sh" show

step "Enrol the preflight namespace into ambient"
run kubectl --context "$CTX" apply -f "$LAB_ROOT/yaml/20-preflight/preflight.yaml"
run kubectl --context "$CTX" -n "$NS_PRE" rollout status deploy/httpbin --timeout=120s
log "the pod is Running (its readiness is not gated on the mesh) — but watch the CA…"

step "Vault says no: the preserved CertificateRequest"
__deadline=$(( $(date +%s) + 120 ))
__cr=""
while [[ -z "$__cr" ]]; do
  __cr="$(kc -n "$ISTIO_SYSTEM_NS" get certificaterequests.cert-manager.io -o json \
    | jq -r '[.items[] | select(.status.conditions[]? | select(.type=="Ready" and .status=="False")
              | .message | test("keys of type rsa"))] | last | .metadata.name // empty')"
  [[ -n "$__cr" ]] && break
  (( $(date +%s) > __deadline )) && die "no rejected CertificateRequest appeared within 120s"
  sleep 5
done
run kubectl --context "$CTX" -n "$ISTIO_SYSTEM_NS" get certificaterequests
echo
echo "--- the Ready condition message on $__cr:"
run kubectl --context "$CTX" -n "$ISTIO_SYSTEM_NS" get certificaterequest "$__cr" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}'
echo

step "And ztunnel's view of the same failure"
run kubectl --context "$CTX" -n "$ISTIO_SYSTEM_NS" logs ds/ztunnel --tail=60 2>/dev/null \
  | grep -iE 'error|warn' | tail -4 || true

ok "rejection confirmed: 'role requires keys of type rsa'. No real workload was harmed."
log "Next: ./scripts/07-vault-allow-ec.sh — the one-line fix."
