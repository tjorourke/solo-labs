#!/usr/bin/env bash
# 08-migrate-payments.sh — migrate the payments namespace to ambient, with
# fortio watching the whole time.
#
# What this does:
#   - starts a 90s fortio load from ledger (sidecar) against payments
#   - swaps the namespace labels: istio.io/dataplane-mode=ambient on,
#     istio-injection off
#   - rolling-restarts the payments deployments so the pods shed their
#     sidecars and come back as plain pods fronted by ztunnel
#   - prints the fortio scoreboard (expect 100% — the deployment carries
#     minReadySeconds so traffic never shifts before ztunnel has the cert)
#   - shows the after-state: no sidecar containers, EC certificates in
#     ztunnel, and live 200s in BOTH directions across the two data planes
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
require istioctl; require openssl; require jq

step "Start the scoreboard: 90s of load from ledger (sidecar) -> payments"
__fortio_out="$(mktemp)"
kc -n "$NS_STAY" exec deploy/fortio -c fortio -- \
  fortio load -c 4 -qps 25 -t 90s -quiet \
  "http://httpbin.${NS_MOVE}:8000/status/200" >"$__fortio_out" 2>&1 &
__fortio_pid=$!
log "fortio running in the background against http://httpbin.${NS_MOVE}:8000/"

step "Migrate: label flip + rolling restart"
run kubectl --context "$CTX" label ns "$NS_MOVE" istio.io/dataplane-mode=ambient istio-injection- --overwrite
run kubectl --context "$CTX" -n "$NS_MOVE" rollout restart deploy/httpbin deploy/client
run kubectl --context "$CTX" -n "$NS_MOVE" rollout status deploy/httpbin deploy/client --timeout=180s

step "The scoreboard (waiting for the 90s window to close)"
wait "$__fortio_pid" || true
grep "Code " "$__fortio_out" || cat "$__fortio_out"
rm -f "$__fortio_out"

step "After-state: no sidecars left in payments"
run kubectl --context "$CTX" -n "$NS_MOVE" get pods \
  -o custom-columns='POD:.metadata.name,CONTAINERS:.spec.containers[*].name'

step "After-state: payments' certificates are now EC, held by ztunnel"
__deadline=$(( $(date +%s) + 120 ))
while true; do
  __algo="$(ztunnel_leaf_pem "$NS_MOVE" httpbin 2>/dev/null | pem_key_algo || true)"
  [[ "$__algo" == "id-ecPublicKey" ]] && break
  (( $(date +%s) > __deadline )) && die "payments did not receive an EC cert within 120s"
  sleep 5
done
echo "payments/httpbin: $__algo (ECDSA P-256)"
echo "ledger/httpbin:   $(sidecar_leaf_pem "$NS_STAY" httpbin | pem_key_algo) (unchanged)"

step "Cross-dataplane traffic, both directions"
sleep 10
echo "ledger (sidecar, RSA) -> payments (ambient, EC):"
run kubectl --context "$CTX" -n "$NS_STAY" logs deploy/client --tail=3
echo "payments (ambient, EC) -> ledger (sidecar, RSA):"
run kubectl --context "$CTX" -n "$NS_MOVE" logs deploy/client --tail=3

ok "payments migrated under load. RSA on one side of every connection, EC on the other, one Vault intermediate signing both."
log "Finish with ./scripts/03-show-certs.sh for the full inventory, or ./scripts/09-sidecar-outage.sh for why the role must stay 'any'."
