#!/usr/bin/env bash
# e2e.sh — the whole lab, automated, with assertions. Exits non-zero on any
# failed assertion.
#
#   1. RSA baseline: kind + Vault (RSA PKI, role key_type=rsa) + cert-manager +
#      istio-csr + Istio sidecar mode
#   2. Apps in ledger + payments (both sidecar), STRICT mTLS, traffic proven
#   3. Both namespaces hold RSA certs chained to the Vault intermediate
#   4. Ambient control plane arrives (istio-csr + istiod config changes) UNDER
#      LOAD — fortio runs across the change and must score 100%; ledger's cert
#      serial must be unchanged afterwards (no re-issuance, no restarts)
#   5. One rolling restart of the sidecar namespace: sidecars injected BEFORE
#      the ambient profile lack ISTIO_META_ENABLE_HBONE, so ztunnel can only
#      send them plaintext (which STRICT rejects). Re-injected sidecars accept
#      HBONE — and their fresh certs are still RSA, proving issuance under the
#      rsa-only role keeps working after ambient arrives
#   6. preflight namespace enrols into ambient: ztunnel's EC CSR is REJECTED by
#      the RSA-only Vault role (this failing is the correct result)
#   7. Vault role flips to key_type=any: preflight gets an EC cert; ledger
#      still RSA, still the same serial as after the roll
#   8. payments migrates to ambient UNDER LOAD: fortio 100%, no sidecar left,
#      EC certs in ztunnel, cross-dataplane traffic 200 both ways
#   9. The sidecar outage: role key_type=ec breaks the next sidecar issuance
#      in ledger (proving why 'any' is the right posture), then any repairs it
#
#   ./scripts/e2e.sh          # everything upstream OSS — no licence, no auth
# Teardown: kind delete cluster --name istio-csr
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
require istioctl; require openssl

FAILS=0
assert() { # assert <label> <got> <want>
  if [[ "$2" == "$3" ]]; then ok "$1: $2"; else warn "$1: got '$2', want '$3'"; FAILS=$((FAILS+1)); fi
}
assert_contains() { # assert_contains <label> <haystack> <needle>
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else warn "$1: '$3' not found"; FAILS=$((FAILS+1)); fi
}
code_of() { kc -n "$1" logs "deploy/$2" --tail=1 2>/dev/null | grep -oE '^[0-9]{3}$' | tail -1; }

# fortio scoreboard: run <seconds> of load from ledger against payments and
# return the "Code 200 : N (P %)" line.
fortio_run() { # <seconds>
  kc -n "$NS_STAY" exec deploy/fortio -c fortio -- \
    fortio load -c 4 -qps 25 -t "${1}s" -quiet \
    "http://httpbin.${NS_MOVE}:8000/status/200" 2>&1 | grep "Code " || true
}

# poll <label> <timeout-s> <cmd...> — until cmd exits 0
poll() {
  local label="$1" timeout="$2"; shift 2
  local start; start="$(date +%s)"
  while true; do
    if "$@" >/dev/null 2>&1; then ok "$label"; return 0; fi
    if (( $(date +%s) - start > timeout )); then warn "$label: timed out after ${timeout}s"; FAILS=$((FAILS+1)); return 1; fi
    sleep 5
  done
}

step "1/9 · RSA baseline (kind + Vault RSA PKI + istio-csr + Istio sidecar)"
"$SCRIPT_DIR/01-setup.sh"

step "2/9 · Deploy ledger + payments (both sidecar) with STRICT mTLS"
kapply "$LAB_ROOT/yaml/10-apps/"
kc -n "$NS_STAY" rollout status deploy/httpbin deploy/client deploy/fortio --timeout=180s >/dev/null
kc -n "$NS_MOVE" rollout status deploy/httpbin deploy/client --timeout=180s >/dev/null
sleep 10
assert "ledger -> payments over mTLS" "$(code_of "$NS_STAY" client)" "200"
assert "payments -> ledger over mTLS" "$(code_of "$NS_MOVE" client)" "200"
SB="$(fortio_run 10)"; assert_contains "fortio baseline 100% 200s" "$SB" "(100.0 %)"

step "3/9 · Both namespaces hold RSA certs chained to Vault"
ALGO_STAY="$(sidecar_leaf_pem "$NS_STAY" httpbin | pem_key_algo)"
ALGO_MOVE="$(sidecar_leaf_pem "$NS_MOVE" httpbin | pem_key_algo)"
ISSUER_STAY="$(sidecar_leaf_pem "$NS_STAY" httpbin | pem_issuer)"
assert "ledger/httpbin key algorithm" "$ALGO_STAY" "rsaEncryption"
assert "payments/httpbin key algorithm" "$ALGO_MOVE" "rsaEncryption"
assert_contains "ledger cert issued by the Vault intermediate" "$ISSUER_STAY" "Lab Intermediate CA"
SERIAL_BEFORE="$(sidecar_leaf_pem "$NS_STAY" httpbin | pem_serial)"
log "ledger/httpbin cert serial (watch it survive the ambient rollout): $SERIAL_BEFORE"

step "4/9 · Ambient control plane arrives UNDER LOAD (istio-csr + istiod reconfigured)"
__fortio_out="$(mktemp)"
kc -n "$NS_STAY" exec deploy/fortio -c fortio -- \
  fortio load -c 4 -qps 25 -t 150s -quiet \
  "http://httpbin.${NS_MOVE}:8000/status/200" >"$__fortio_out" 2>&1 &
__fortio_pid=$!
"$SCRIPT_DIR/04-enable-ambient.sh"
wait "$__fortio_pid" || true
assert_contains "fortio 100% across the istio-csr/istiod change" "$(grep 'Code ' "$__fortio_out")" "(100.0 %)"
rm -f "$__fortio_out"
SERIAL_AFTER="$(sidecar_leaf_pem "$NS_STAY" httpbin | pem_serial)"
assert "ledger cert serial unchanged (no re-issuance, no restart)" "$SERIAL_AFTER" "$SERIAL_BEFORE"

step "5/9 · One rolling restart of ledger: sidecars re-inject with HBONE interop"
# Sidecars injected before the ambient profile lack ISTIO_META_ENABLE_HBONE:
# istiod advertises them as non-HBONE workloads, so ztunnel could only reach
# them in plaintext — which STRICT mTLS rejects. Roll them ONCE (before any
# neighbour migrates); they come back as sidecars, HBONE-capable, and their
# fresh certs are still RSA because the Vault role is still rsa-only.
kc -n "$NS_STAY" rollout restart deploy/httpbin deploy/client deploy/fortio >/dev/null
kc -n "$NS_STAY" rollout status deploy/httpbin deploy/client deploy/fortio --timeout=180s >/dev/null
sleep 10
# The proof that matters is istiod's own advertisement: once the re-injected
# sidecars (ISTIO_META_ENABLE_HBONE=true) reconnect, every ledger workload row
# in ztunnel's config shows PROTOCOL=HBONE. Poll until the old TCP rows age out.
ledger_all_hbone() {
  local zt protos
  zt="$(kc -n "$ISTIO_SYSTEM_NS" get pods -l app=ztunnel -o jsonpath='{.items[0].metadata.name}')"
  protos="$(ic ztunnel-config workloads "$zt.$ISTIO_SYSTEM_NS" 2>/dev/null \
    | awk -v ns="$NS_STAY" '$1==ns {print $6}' | sort -u)"
  [[ "$protos" == "HBONE" ]]
}
poll "istiod advertises every rolled ledger sidecar as HBONE-capable" 120 ledger_all_hbone
assert "fresh ledger cert is STILL RSA (rsa-only role still serving sidecars)" \
  "$(sidecar_leaf_pem "$NS_STAY" httpbin | pem_key_algo)" "rsaEncryption"
SERIAL_ROLLED="$(sidecar_leaf_pem "$NS_STAY" httpbin | pem_serial)"
assert "ledger -> payments still 200 after the roll" "$(code_of "$NS_STAY" client)" "200"

step "6/9 · preflight enrols into ambient — the RSA-only role says no"
kapply "$LAB_ROOT/yaml/20-preflight/preflight.yaml"
kc -n "$NS_PRE" rollout status deploy/httpbin --timeout=120s >/dev/null
cr_rejected() {
  kc -n "$ISTIO_SYSTEM_NS" get certificaterequests.cert-manager.io -o json \
    | jq -e '[.items[] | select(.status.conditions[]? | select(.type=="Ready" and .status=="False")
              | .message | test("keys of type rsa"))] | length > 0'
}
poll "CertificateRequest denied: 'role requires keys of type rsa'" 120 cr_rejected
PRE_PEM="$(ztunnel_leaf_pem "$NS_PRE" httpbin || true)"
if [[ "$PRE_PEM" == *BEGIN* ]]; then
  warn "preflight unexpectedly has a cert already"; FAILS=$((FAILS+1))
else
  ok "ztunnel holds no cert for preflight (as expected while the role is rsa-only)"
fi

step "7/9 · Flip the Vault role to key_type=any"
"$SCRIPT_DIR/vault-pki.sh" role any
pre_cert_ec() { [[ "$(ztunnel_leaf_pem "$NS_PRE" httpbin | pem_key_algo)" == "id-ecPublicKey" ]]; }
poll "preflight now holds an EC (P-256) cert from Vault" 180 pre_cert_ec
assert "ledger STILL RSA" "$(sidecar_leaf_pem "$NS_STAY" httpbin | pem_key_algo)" "rsaEncryption"
assert "ledger serial unchanged by the role flip" "$(sidecar_leaf_pem "$NS_STAY" httpbin | pem_serial)" "$SERIAL_ROLLED"

step "8/9 · Migrate payments to ambient UNDER LOAD"
__fortio_out="$(mktemp)"
kc -n "$NS_STAY" exec deploy/fortio -c fortio -- \
  fortio load -c 4 -qps 25 -t 90s -quiet \
  "http://httpbin.${NS_MOVE}:8000/status/200" >"$__fortio_out" 2>&1 &
__fortio_pid=$!
kc label ns "$NS_MOVE" istio.io/dataplane-mode=ambient istio-injection- --overwrite >/dev/null
kc -n "$NS_MOVE" rollout restart deploy/httpbin deploy/client >/dev/null
kc -n "$NS_MOVE" rollout status deploy/httpbin deploy/client --timeout=180s >/dev/null
wait "$__fortio_pid" || true
assert_contains "fortio 100% across the migration" "$(grep 'Code ' "$__fortio_out")" "(100.0 %)"
rm -f "$__fortio_out"
CONTAINERS="$(kc -n "$NS_MOVE" get pods -l app=httpbin -o jsonpath='{.items[0].spec.containers[*].name}')"
assert "payments/httpbin has no sidecar" "$CONTAINERS" "httpbin"
mv_cert_ec() { [[ "$(ztunnel_leaf_pem "$NS_MOVE" httpbin | pem_key_algo)" == "id-ecPublicKey" ]]; }
poll "payments holds an EC cert in ztunnel" 120 mv_cert_ec
sleep 10
assert "ledger -> payments (sidecar -> ambient) still 200" "$(code_of "$NS_STAY" client)" "200"
assert "payments -> ledger (ambient -> sidecar) still 200" "$(code_of "$NS_MOVE" client)" "200"
assert "ledger untouched: RSA" "$(sidecar_leaf_pem "$NS_STAY" httpbin | pem_key_algo)" "rsaEncryption"

step "9/9 · The sidecar outage: key_type=ec (why 'any', not 'ec')"
"$SCRIPT_DIR/vault-pki.sh" role ec
kc -n "$NS_STAY" scale deploy/httpbin --replicas=2 >/dev/null
cr_rejected_ec() {
  kc -n "$ISTIO_SYSTEM_NS" get certificaterequests.cert-manager.io -o json \
    | jq -e '[.items[] | select(.status.conditions[]? | select(.type=="Ready" and .status=="False")
              | .message | test("keys of type ec"))] | length > 0'
}
poll "new ledger sidecar REJECTED: 'role requires keys of type ec'" 180 cr_rejected_ec
"$SCRIPT_DIR/vault-pki.sh" role any
poll "role back to 'any': second ledger replica becomes Ready" 240 \
  kc -n "$NS_STAY" wait --for=condition=Available deploy/httpbin --timeout=5s
kc -n "$NS_STAY" scale deploy/httpbin --replicas=1 >/dev/null

echo
"$SCRIPT_DIR/03-show-certs.sh" || true
if (( FAILS == 0 )); then
  ok "E2E PASSED — RSA sidecars untouched, EC only where ambient took over, zero dropped requests."
else
  warn "E2E FAILED — $FAILS assertion(s) failed"
  exit 1
fi
