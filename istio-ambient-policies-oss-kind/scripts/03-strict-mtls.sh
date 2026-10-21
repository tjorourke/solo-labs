#!/usr/bin/env bash
# 03-strict-mtls.sh: Policy 1, STRICT mTLS on the ratings pods.
#
# One PeerAuthentication in bookinfo with a selector for app=ratings, generated
# by Flightbay's "Require mTLS" task. The legacy caller is not in the mesh and
# sends plaintext, so ztunnel resets it. reviews and demo-client see no change.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require kubectl

step "Policy 1: PeerAuthentication STRICT on the ratings pods (YAML from Flightbay)"
show kc apply -f "$LAB_ROOT/yaml/20-policies/10-peerauth-strict.yaml"
wait_code 000 "$NS_LEGACY" legacy GET

step "Probe"
"$SCRIPT_DIR/probe.sh" --no-jwt
log "legacy is reset before any HTTP is exchanged. reviews-v2 and demo-client still get 200:"
log "they were already on mTLS, so STRICT changed nothing for them."

echo
ok "Policy 1 in place: ratings refuses plaintext."
log "Next: ./scripts/04-l4-authz.sh"
