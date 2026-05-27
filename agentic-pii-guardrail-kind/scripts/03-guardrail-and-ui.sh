#!/usr/bin/env bash
# 03-guardrail-and-ui.sh — build + kind-load + deploy the two custom services.
#
#   pii-guardrail-webhook — Python FastAPI: /request, /response, /events
#   inspector-ui          — Go HTMX: chat + redaction trace
#
# Then applies the namespace and the two Deployment/Service manifests.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

# ── 1. Build + load images ────────────────────────────────────────────────────
step "Building and loading custom images into kind"
build_and_load "$LAB_ROOT/src/guardrail-webhook" "$GUARDRAIL_WEBHOOK_IMAGE"
build_and_load "$LAB_ROOT/src/inspector-ui"     "$INSPECTOR_UI_IMAGE"

# ── 2. Namespaces ─────────────────────────────────────────────────────────────
step "Creating namespaces"
kc apply -f "$LAB_ROOT/yaml/namespaces/00-namespaces.yaml" >/dev/null
ok "pii-demo namespace ready"

# ── 3. Deploy guardrail webhook ───────────────────────────────────────────────
step "Deploying pii-guardrail-webhook"
kc apply -f "$LAB_ROOT/yaml/guardrail/deployment.yaml" >/dev/null
wait_deploy pii-demo pii-guardrail-webhook 120s
ok "pii-guardrail-webhook ready"

# ── 4. Deploy inspector UI ────────────────────────────────────────────────────
step "Deploying inspector-ui"
kc apply -f "$LAB_ROOT/yaml/inspector/deployment.yaml" >/dev/null
wait_deploy pii-demo inspector-ui 120s
ok "inspector-ui ready"

step "Custom services deployed"
echo "  Next: ./scripts/04-policy.sh" >&2
