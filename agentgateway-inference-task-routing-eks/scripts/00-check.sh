#!/usr/bin/env bash
# What the flow steps need before they change anything: the platform up and working.
#
#   ./scripts/00-check.sh
#
# The flow steps need the platform: a cluster with both models serving, the semantic router
# running, the public gateway Programmed, and an Anthropic key in the environment for the one
# frontier route. scripts/platform/up.sh builds the platform when it is not there. This stops
# here rather than failing three steps later with an error about the wrong thing.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/scripts/lib.sh"
set +e
fail=0
ok()  { printf "  ok    %s\n" "$*"; }
bad() { printf "  FAIL  %s\n" "$*"; fail=1; }
echo "context: $CTX"
for d in vllm vllm-qwen; do
  if [ "$(kubectl -n models get deploy "$d" -o jsonpath='{.status.availableReplicas}' 2>/dev/null)" = "1" ]; then ok "$d is serving"
  else bad "$d is not ready. Install the platform with ./scripts/platform/up.sh, or if the GPU node is scaled to zero run ./scripts/platform/gpu.sh up"; fi
done
if [ "$(kubectl -n "$NS" get deploy semantic-router -o jsonpath='{.status.availableReplicas}' 2>/dev/null)" = "1" ]; then ok "semantic-router is running (02-router.sh reconfigures it)"; else echo "  note  semantic-router not installed yet; 02-router.sh installs it"; fi
if [ "$(kubectl -n "$NS" get gateway model-gateway -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)" = "True" ]; then ok "model-gateway is Programmed"; else bad "model-gateway is not Programmed"; fi
if [ -f "$PART3_DIR/identity/signing-key.pem" ]; then ok "Part 3 signing key found (reused, so the JWKS does not change)"; else echo "  note  no Part 3 signing key; 01-identity.sh generates a new one"; fi
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then ok "ANTHROPIC_API_KEY set"; else bad "ANTHROPIC_API_KEY not set (export it, or source your secrets file)"; fi
echo
if [ "$fail" = 0 ]; then echo "Ready. Next: ./scripts/01-identity.sh"; else echo "Fix the FAIL lines above."; exit 1; fi
