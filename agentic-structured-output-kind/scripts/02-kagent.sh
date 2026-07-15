#!/usr/bin/env bash
# 02-kagent.sh — install OSS kagent (CRDs + controller + bundled tool server),
# wired to Anthropic. The chart's providers block creates the default-model-config
# (Anthropic). We also drop a plain kagent-anthropic Secret for the BYO agent's env.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_secrets

step "Namespace + Anthropic secret (for the BYO agent env)"
kc create namespace kagent --dry-run=client -o yaml | kc apply -f - >/dev/null
# Our own secret for the BYO agent's env. Named distinctly so it does not collide
# with the kagent-anthropic secret the chart's providers block creates+owns.
kc -n kagent create secret generic dba-anthropic \
  --from-literal=ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
ok "kagent namespace + dba-anthropic secret ready"

step "Installing kagent CRDs $KAGENT_VERSION"
helm --kube-context "$CTX" upgrade --install kagent-crds "$KAGENT_CRDS_CHART" \
  --namespace kagent --create-namespace --version "$KAGENT_VERSION" --wait --timeout 5m >/dev/null
ok "kagent CRDs installed"

step "Installing kagent controller $KAGENT_VERSION (Anthropic + tool server)"
log "image pulls (controller + postgres + tools) can take several minutes"
helm_install_with_progress kagent "$KAGENT_CHART" kagent \
  --version "$KAGENT_VERSION" \
  --set providers.default=anthropic \
  --set providers.anthropic.apiKey="${ANTHROPIC_API_KEY}" \
  --set providers.anthropic.model="${KAGENT_MODEL}" \
  --set kagent-tools.enabled=true \
  --wait --timeout 12m
ok "kagent controller installed"

step "Waiting for controller + tool server"
wait_deploy kagent kagent-controller 360s || warn "controller not Available in 6m — continuing"
kc -n kagent get remotemcpserver kagent-tool-server >/dev/null 2>&1 \
  && ok "kagent-tool-server present" || warn "kagent-tool-server not found — the orchestrator's k8s tools may be missing"
kc -n kagent get modelconfig default-model-config >/dev/null 2>&1 \
  && ok "default-model-config present" || warn "default-model-config not created by the chart — check providers values"

step "kagent installed"; echo "  Next: ./scripts/03-images.sh" >&2
