#!/usr/bin/env bash
# 05-interop-roll.sh — one rolling restart of the sidecar namespace, BEFORE
# anything migrates to ambient.
#
# Why this step exists: sidecars injected before istiod moved to the ambient
# profile lack ISTIO_META_ENABLE_HBONE, so istiod advertises them as workloads
# that cannot accept HBONE. ztunnel's only way to reach them would be
# plaintext, and STRICT mTLS (correctly) resets that. The symptom, if you skip
# this, shows up later and looks baffling: ambient callers get connection
# resets from sidecar services that sidecar callers reach fine.
#
# What this does:
#   - rolling restart of every ledger deployment (they come back as sidecars)
#   - shows istiod now advertising them as HBONE-capable (PROTOCOL column)
#   - shows their fresh certificates are STILL RSA: the rsa-only Vault role
#     keeps serving sidecars perfectly well after ambient arrives
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
require istioctl; require openssl; require jq

step "Roll the ledger deployments once (they stay on sidecars)"
run kubectl --context "$CTX" -n "$NS_STAY" rollout restart deploy/httpbin deploy/client deploy/fortio
run kubectl --context "$CTX" -n "$NS_STAY" rollout status deploy/httpbin deploy/client deploy/fortio --timeout=180s
sleep 10

step "Proof 1 — istiod now advertises the rolled sidecars as HBONE-capable"
ZT="$(kc -n "$ISTIO_SYSTEM_NS" get pods -l app=ztunnel -o jsonpath='{.items[0].metadata.name}')"
run istioctl --context "$CTX" ztunnel-config workloads "$ZT.$ISTIO_SYSTEM_NS" 2>/dev/null | grep -E "NAMESPACE|^$NS_STAY "

step "Proof 2 — the re-injected sidecar carries the HBONE flag"
run kubectl --context "$CTX" -n "$NS_STAY" get pods -l app=httpbin \
  -o jsonpath='{range .items[*]}{.metadata.name}: ISTIO_META_ENABLE_HBONE={.spec.containers[?(@.name=="istio-proxy")].env[?(@.name=="ISTIO_META_ENABLE_HBONE")].value}{"\n"}{end}'

step "Proof 3 — the fresh certificate is still RSA (role is still rsa-only)"
echo "ledger/httpbin key algorithm: $(sidecar_leaf_pem "$NS_STAY" httpbin | pem_key_algo)"

ok "ledger is HBONE-ready and still entirely RSA. Nothing about its key type changed."
log "Next: ./scripts/06-preflight-break.sh — the first ambient enrolment, somewhere safe."
