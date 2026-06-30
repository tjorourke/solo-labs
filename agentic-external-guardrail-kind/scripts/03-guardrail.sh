#!/usr/bin/env bash
# 03-guardrail.sh — build + kind-load + deploy the two custom services:
#
#   trustguard-stub — local stand-in for the external guardrail verdict API
#                     (POST /v1/guard). Swap for real NeuralTrust via GUARD_URL.
#   guard-adapter   — agentgateway Custom Guardrails Webhook that forwards the
#                     canonical messages/choices to the external guard.
#
# The adapter's GUARD_URL / GUARD_API_KEY / GUARD_MODE come from lib.sh env, so
# `GUARD_MODE=neuraltrust GUARD_URL=... GUARD_API_KEY=... ./scripts/03-guardrail.sh`
# re-points it at the real service without touching any manifest.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

# ── 1. Build + load images ────────────────────────────────────────────────────
step "Building and loading custom images into kind"
build_and_load "$LAB_ROOT/src/trustguard-stub" "$TRUSTGUARD_STUB_IMAGE"
build_and_load "$LAB_ROOT/src/guard-adapter"   "$GUARD_ADAPTER_IMAGE"

# ── 2. Namespace ──────────────────────────────────────────────────────────────
step "Creating namespace"
kc apply -f "$LAB_ROOT/yaml/namespaces/00-namespaces.yaml" >/dev/null
ok "extguard-demo namespace ready"

# ── 3. Deploy trustguard-stub (skipped automatically in real mode) ────────────
if [[ "$GUARD_MODE" == "stub" ]]; then
  step "Deploying trustguard-stub (local guardrail stand-in)"
  kc apply -f "$LAB_ROOT/yaml/guardrail/stub-deployment.yaml" >/dev/null
  wait_deploy extguard-demo trustguard-stub 120s
  ok "trustguard-stub ready"
else
  step "Real guardrail mode ($GUARD_MODE) — skipping stub deploy"
  log "adapter will call: $GUARD_URL"
fi

# ── 4. Deploy guard-adapter (the AGW webhook) ─────────────────────────────────
step "Deploying guard-adapter"
# Render GUARD_* env into the adapter Deployment.
sed \
  -e "s|__GUARD_URL__|${GUARD_URL}|g" \
  -e "s|__GUARD_MODE__|${GUARD_MODE}|g" \
  "$LAB_ROOT/yaml/guardrail/adapter-deployment.yaml" \
  | kc apply -f - >/dev/null

# API key (if any) goes via a Secret, never inline in the manifest.
kc -n extguard-demo create secret generic guard-api-key \
  --from-literal=GUARD_API_KEY="${GUARD_API_KEY}" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null

wait_deploy extguard-demo guard-adapter 120s
ok "guard-adapter ready (mode=$GUARD_MODE)"

step "Custom services deployed"
echo "  Next: ./scripts/04-policy.sh" >&2
