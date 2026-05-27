#!/usr/bin/env bash
# 03-kagent.sh — install kagent OSS in the kagent namespace.
#
# The BYO LangGraph chat agents in this lab talk to the gateway-fronted mock
# LLM directly via httpx — they do NOT use ChatAnthropic. So no Anthropic key
# is strictly required. We still install kagent with a default-model
# placeholder so the dashboard's built-in "ask kagent" features work; if
# ANTHROPIC_API_KEY isn't set we wire a no-op string and let the dashboard
# surface its own error if anyone tries to use the built-in agent.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

load_secrets

# kagent-crds + kagent ship as separate OCI Helm charts.
KAGENT_CRDS_CHART="oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds"
KAGENT_CHART="oci://ghcr.io/kagent-dev/kagent/helm/kagent"

KAGENT_HELM_ARGS=(--namespace kagent --create-namespace --wait --timeout 10m)
[[ -n "$KAGENT_VERSION" ]] && KAGENT_HELM_ARGS+=(--version "$KAGENT_VERSION")

step "Installing kagent CRDs"
helm --kube-context "$CTX" upgrade --install kagent-crds "$KAGENT_CRDS_CHART" \
  "${KAGENT_HELM_ARGS[@]}" >/dev/null
ok "kagent CRDs installed"

step "Installing kagent"
log "image pulls from ghcr.io can take 2-4 min on a cold cluster — progress every 15s below"

# Use Anthropic if provided; otherwise the kagent default-model stub. The BYO
# chat agents don't care either way — they wire the mock-LLM URL into httpx.
ANTHROPIC_ARGS=()
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  ANTHROPIC_ARGS=(
    --set providers.default=anthropic
    --set providers.anthropic.apiKey="${ANTHROPIC_API_KEY}"
  )
  log "kagent default model: anthropic (claude-haiku-4-5)"
else
  log "ANTHROPIC_API_KEY not set — installing kagent with chart-default model config"
  log "(BYO chat agents in this lab don't need an Anthropic key; they call the mock LLM directly)"
fi

helm_install_with_progress kagent "$KAGENT_CHART" kagent \
  --wait --timeout 10m \
  ${KAGENT_VERSION:+--version "$KAGENT_VERSION"} \
  "${ANTHROPIC_ARGS[@]}"
ok "kagent control plane installed"

step "Waiting for kagent controller + UI"
wait_deploy kagent kagent-controller 300s || warn "controller did not become Available in 5m — continuing"
wait_deploy kagent kagent-ui 300s         || warn "UI did not become Available in 5m — continuing"
ok "kagent ready"

step "kagent installed"
echo "  Namespace: kagent" >&2
echo "  Next:      ./scripts/04-llm-and-jwt.sh" >&2
