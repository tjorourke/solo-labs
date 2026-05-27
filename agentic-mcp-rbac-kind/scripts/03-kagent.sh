#!/usr/bin/env bash
# 03-kagent.sh — install kagent OSS in the kagent namespace.
#
# Same as the agentic-hitl-kind equivalent. The chart default model under
# providers.anthropic is claude-haiku-4-5 — cheap + fast.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_secrets

KAGENT_CRDS_CHART="oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds"
KAGENT_CHART="oci://ghcr.io/kagent-dev/kagent/helm/kagent"

KAGENT_HELM_ARGS=(--namespace kagent --create-namespace --wait --timeout 10m)
[[ -n "$KAGENT_VERSION" ]] && KAGENT_HELM_ARGS+=(--version "$KAGENT_VERSION")

step "Installing kagent CRDs"
helm --kube-context "$CTX" upgrade --install kagent-crds "$KAGENT_CRDS_CHART" \
  "${KAGENT_HELM_ARGS[@]}" >/dev/null
ok "kagent CRDs installed"

step "Installing kagent (Anthropic provider)"
log "image pulls from ghcr.io can take 2-4 min on a cold cluster — progress every 15s below"
helm_install_with_progress kagent "$KAGENT_CHART" kagent \
  --wait --timeout 10m \
  ${KAGENT_VERSION:+--version "$KAGENT_VERSION"} \
  --set providers.default=anthropic \
  --set providers.anthropic.apiKey="${ANTHROPIC_API_KEY}"
ok "kagent control plane installed (model: claude-haiku-4-5)"

step "Waiting for kagent controller + UI"
wait_deploy kagent kagent-controller 300s || warn "controller did not become Available in 5m — continuing"
wait_deploy kagent kagent-ui 300s         || warn "UI did not become Available in 5m — continuing"
ok "kagent ready"

step "kagent installed"
echo "  Namespace: kagent" >&2
echo "  Next:      ./scripts/04-mcp-and-jwt.sh" >&2
