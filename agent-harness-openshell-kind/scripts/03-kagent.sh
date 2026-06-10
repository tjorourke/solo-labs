#!/usr/bin/env bash
# 03-kagent.sh — install kagent OSS and point its controller at OpenShell.
#
# The only AgentHarness-specific wiring kagent needs is the controller env var
# OPENSHELL_GRPC_ADDR. When it is empty the controller does not register the
# AgentHarness backends, so the harness never goes Ready. We set it to the
# in-cluster OpenShell Service from 02-openshell.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_secrets

KAGENT_HELM_ARGS=(--namespace kagent --create-namespace --wait --timeout 10m)
[[ -n "$KAGENT_VERSION" ]] && KAGENT_HELM_ARGS+=(--version "$KAGENT_VERSION")

step "Installing kagent CRDs"
helm --kube-context "$CTX" upgrade --install kagent-crds "$KAGENT_CRDS_CHART" \
  "${KAGENT_HELM_ARGS[@]}" >/dev/null
ok "kagent CRDs installed"

# Confirm the AgentHarness CRD actually shipped (landed in kagent OSS 0.9.2).
if kc get crd agentharnesses.kagent.dev >/dev/null 2>&1; then
  ok "AgentHarness CRD present"
else
  warn "agentharnesses.kagent.dev CRD not found — your kagent chart may predate 0.9.2."
  warn "Set KAGENT_VERSION to >=0.9.2 and re-run."
fi

step "Installing kagent"
log "default model: anthropic (claude-haiku-4-5)"
log "controller → OpenShell gRPC: $OPENSHELL_GRPC_ADDR"
log "image pulls from ghcr.io can take 2-4 min on a cold cluster — progress every 15s"

helm_install_with_progress kagent "$KAGENT_CHART" kagent \
  --wait --timeout 10m \
  ${KAGENT_VERSION:+--version "$KAGENT_VERSION"} \
  --set providers.default=anthropic \
  --set providers.anthropic.apiKey="${ANTHROPIC_API_KEY}" \
  --set 'controller.env[0].name=OPENSHELL_GATEWAY_URL' \
  --set-string "controller.env[0].value=dns:///${OPENSHELL_GRPC_ADDR}" \
  --set 'controller.env[1].name=OPENSHELL_INSECURE' \
  --set-string 'controller.env[1].value=true'
ok "kagent control plane installed"

step "Waiting for kagent controller + UI"
wait_deploy kagent kagent-controller 300s || warn "controller did not become Available in 5m — continuing"
wait_deploy kagent kagent-ui 300s         || warn "UI did not become Available in 5m — continuing"
ok "kagent ready"

step "kagent installed"
echo "  Namespace: kagent" >&2
echo "  Next:      ./scripts/04-harness.sh" >&2
