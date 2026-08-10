#!/usr/bin/env bash
# 30-vault-role.sh <rsa|any> — rewrite the mesh CA's signing role in Vault.
#
#   ./30-vault-role.sh rsa    # RSA CSRs only — the estate's existing posture,
#                             # and the posture that rejects ztunnel
#   ./30-vault-role.sh any    # RSA and EC — the posture ambient needs
#
# `vault write` on a role REPLACES it rather than patching it, so the full
# parameter set goes on every write. Leave one field out and you silently drop
# it.
#
# Never write key_type=ec while any sidecar is still running: sidecars send RSA
# CSRs, so an EC-only role is a sidecar outage on a one-hour timer (the cert TTL),
# not an immediate failure you would notice straight away.
set -euo pipefail

KT="${1:?usage: 30-vault-role.sh <rsa|any>}"
BITS=""
[[ "$KT" == "rsa" ]] && BITS="key_bits=2048"

kubectl -n vault exec vault-0 -- sh -c "
VAULT_TOKEN=root VAULT_ADDR=http://127.0.0.1:8200 vault write pki_int/roles/istio-ca \
  allowed_uri_sans='spiffe://*' \
  allow_any_name=true \
  enforce_hostnames=false \
  require_cn=false \
  server_flag=true \
  client_flag=true \
  key_type=$KT $BITS \
  ttl=1h max_ttl=24h"

kubectl -n vault exec vault-0 -- sh -c \
  'VAULT_TOKEN=root VAULT_ADDR=http://127.0.0.1:8200 vault read -field=key_type pki_int/roles/istio-ca'
