#!/usr/bin/env bash
# 07-vault-allow-ec.sh — the fix: set the Vault role to key_type=any.
#
# Why any and not ec: the key type of a workload certificate is chosen by the
# CLIENT. Sidecars (istio-agent) send RSA-2048 CSRs; ztunnel sends ECDSA
# P-256. With key_type=any, Vault signs whichever arrives, so both data
# planes are served by the same role and the same RSA intermediate. Setting
# ec instead would break the next RSA renewal for every sidecar still
# running (script 09 proves that, deliberately).
#
# What this does:
#   - rewrites the Vault role with key_type=any (a role write REPLACES the
#     role, so the full parameter set is rewritten every time)
#   - waits for ztunnel's retry loop to pick it up and shows preflight's new
#     EC certificate
#   - shows ledger's sidecar certificate is untouched: still RSA, same serial
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
require istioctl; require openssl; require jq

step "Ledger's certificate BEFORE the change (keep the serial in view)"
__before_serial="$(sidecar_leaf_pem "$NS_STAY" httpbin | pem_serial)"
echo "ledger/httpbin: $(sidecar_leaf_pem "$NS_STAY" httpbin | pem_key_algo), serial $__before_serial"

step "Flip the Vault role to key_type=any"
"$SCRIPT_DIR/vault-pki.sh" role any
"$SCRIPT_DIR/vault-pki.sh" show

step "ztunnel retries and preflight gets its EC certificate"
__deadline=$(( $(date +%s) + 180 ))
while true; do
  __algo="$(ztunnel_leaf_pem "$NS_PRE" httpbin 2>/dev/null | pem_key_algo || true)"
  [[ "$__algo" == "id-ecPublicKey" ]] && break
  (( $(date +%s) > __deadline )) && die "preflight did not receive an EC cert within 180s"
  sleep 5
done
echo "preflight/httpbin: $__algo (ECDSA P-256), issued by:"
ztunnel_leaf_pem "$NS_PRE" httpbin | pem_issuer

step "Ledger AFTER the change — nothing happened to it"
echo "ledger/httpbin: $(sidecar_leaf_pem "$NS_STAY" httpbin | pem_key_algo), serial $(sidecar_leaf_pem "$NS_STAY" httpbin | pem_serial)"
[[ "$(sidecar_leaf_pem "$NS_STAY" httpbin | pem_serial)" == "$__before_serial" ]] \
  && ok "same serial: the role flip caused no re-issuance and no restarts anywhere" \
  || warn "serial changed — unexpected, investigate"

log "Next: ./scripts/08-migrate-payments.sh — the real migration, under load."
