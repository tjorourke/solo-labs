#!/usr/bin/env bash
# 04-semantic-router.sh — install the upstream vLLM Semantic Router as a gRPC
# ExtProc service in agentgateway-system.
#
# The router is gateway-flavour-agnostic — it is just an ExtProc server. We use
# the vendored agentgateway preset values (yaml/semantic-router/values.yaml),
# which point the router at the in-cluster vLLM Service and map prompt
# categories to LoRA adapters.
#
# IMPORTANT: on first start the router downloads several GB of classification
# models from the HuggingFace Hub into its PVC. The gRPC server on :50051 only
# binds AFTER that finishes, so the pod stays 0/1 (startup probe failing) for
# the whole download. Unauthenticated HF pulls are rate-limited and slow — set
# HF_TOKEN to authenticate and speed them up. We do NOT use helm --wait here
# (it would time out mid-download and mark the release failed); instead we poll
# the deployment ourselves with a long timeout and print disk progress.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

load_secrets

# Optional HF token — dramatically faster model downloads. The chart reads it
# from the secret 'hf-token-secret' (key 'token'), referenced as optional.
if [[ -n "${HF_TOKEN:-}" ]]; then
  step "Creating hf-token-secret (authenticated HF downloads)"
  kc create namespace agentgateway-system >/dev/null 2>&1 || true
  kc -n agentgateway-system create secret generic hf-token-secret \
    --from-literal=token="${HF_TOKEN}" \
    --dry-run=client -o yaml | kc apply -f - >/dev/null
  ok "hf-token-secret applied"
else
  warn "HF_TOKEN not set — model downloads will be unauthenticated (slow, rate-limited)."
  warn "Export HF_TOKEN=hf_... before this step for much faster first start."
fi

step "Installing vLLM Semantic Router $SEMANTIC_ROUTER_VERSION"
# No --wait: the release is 'deployed' once resources apply; readiness (the
# multi-GB model download) is handled by the poll below.
helm --kube-context "$CTX" upgrade --install semantic-router "$SEMANTIC_ROUTER_CHART" \
  --namespace agentgateway-system --create-namespace \
  --version "$SEMANTIC_ROUTER_VERSION" \
  -f "$LAB_ROOT/yaml/semantic-router/values.yaml" >/dev/null
ok "semantic-router chart applied"

# ── wait for readiness, printing download progress ────────────────────────────
step "Waiting for the router to download models and bind :50051"
log "first start pulls several GB of classification models — be patient"
TIMEOUT="${SEMANTIC_ROUTER_TIMEOUT:-1800}"   # 30 min default
end=$(( $(date +%s) + TIMEOUT ))
ready=""
until [[ -n "$ready" ]]; do
  ready="$(kc -n agentgateway-system get deploy semantic-router \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null | grep True || true)"
  [[ -n "$ready" ]] && break
  if [[ $(date +%s) -ge $end ]]; then
    warn "router not Available within $((TIMEOUT/60))m — check: kc -n agentgateway-system logs deploy/semantic-router"
    exit 1
  fi
  du="$(kc -n agentgateway-system exec deploy/semantic-router -- \
    du -sh /app/models 2>/dev/null | awk '{print $1}' || true)"
  log "[downloading] models on disk: ${du:-0} (probe waits up to 60m)"
  sleep 20
done
ok "semantic-router ready (gRPC ExtProc on :50051)"

step "Semantic Router ready"
echo "  gRPC ExtProc endpoint: semantic-router.agentgateway-system.svc:50051" >&2
echo "  Next: ./scripts/05-routing.sh" >&2
