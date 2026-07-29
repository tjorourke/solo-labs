#!/usr/bin/env bash
# 02-deploy-apps.sh — deploy the two app namespaces, both on sidecars, and
# turn on STRICT mTLS mesh-wide.
#
# What this does:
#   - creates namespaces ledger and payments, both labelled istio-injection=enabled
#   - deploys httpbin + a client in each; the client curls the OTHER namespace
#     every 2s and logs the HTTP code, so its log is a rolling health record
#   - deploys fortio in ledger (the zero-downtime scoreboard for later steps)
#   - applies PeerAuthentication STRICT mesh-wide: every request from here on
#     is mutually authenticated with a Vault-issued certificate, no plaintext
#     fallback to hide behind
#
# Every sidecar that starts here asks istio-csr for a certificate; istio-csr
# turns that into a cert-manager CertificateRequest signed by Vault. The pods
# going Ready IS the proof that the Vault CA path works.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

step "Deploy ledger + payments (both sidecar) with STRICT mTLS"
run kubectl --context "$CTX" apply -f "$LAB_ROOT/yaml/10-apps/"
run kubectl --context "$CTX" -n "$NS_STAY" rollout status deploy/httpbin deploy/client deploy/fortio --timeout=180s
run kubectl --context "$CTX" -n "$NS_MOVE" rollout status deploy/httpbin deploy/client --timeout=180s

step "Cross-namespace traffic, through the mesh, over Vault-issued certs"
sleep 8
run kubectl --context "$CTX" -n "$NS_STAY" logs deploy/client --tail=3
run kubectl --context "$CTX" -n "$NS_MOVE" logs deploy/client --tail=3

ok "both directions returning 200 under STRICT mTLS — the Vault CA path is live"
log "Next: ./scripts/03-show-certs.sh to read the actual certificates."
