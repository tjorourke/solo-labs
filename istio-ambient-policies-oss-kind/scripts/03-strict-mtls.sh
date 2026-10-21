#!/usr/bin/env bash
# 03-strict-mtls.sh — Policy 1: mesh-wide STRICT mTLS.
#
# One PeerAuthentication in istio-system. The legacy caller, which is not in
# the mesh and speaks plaintext, is reset by ztunnel. Nothing in shop notices.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require kubectl

step "Policy 1: PeerAuthentication STRICT, mesh-wide"
show kc apply -f "$LAB_ROOT/yaml/20-policies/10-peerauth-strict.yaml"
sleep 2

step "Probe"
"$SCRIPT_DIR/probe.sh" --no-jwt
log "legacy is reset before any HTTP is exchanged. checkout and reporting still get 200:"
log "they were already on mTLS, so STRICT changed nothing for them."

echo
ok "Policy 1 in place: the mesh refuses plaintext."
log "Next: ./scripts/04-l4-authz.sh"
