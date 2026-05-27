#!/usr/bin/env bash
# 04-policy.sh — Apply the Gateway, AgentgatewayBackend, HTTPRoute, and the
# EnterpriseAgentgatewayPolicy that wires the two prompt-guard layers
# (built-in regex + custom webhook) onto the Anthropic route.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_secrets

# ── 1. Anthropic API key secret ───────────────────────────────────────────────
# Lives in agentgateway-system because the AgentgatewayBackend that references
# it (via policies.auth.secretRef) is in the same namespace.
step "Creating anthropic-secret in agentgateway-system"
kc -n agentgateway-system create secret generic anthropic-secret \
  --from-literal=Authorization="${ANTHROPIC_API_KEY}" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
ok "anthropic-secret applied"

# ── 2. Gateway, Backend, HTTPRoute ────────────────────────────────────────────
step "Applying Gateway + AgentgatewayBackend + HTTPRoute"
kc apply -f "$LAB_ROOT/yaml/agentgateway/gateway.yaml" >/dev/null
kc apply -f "$LAB_ROOT/yaml/agentgateway/anthropic-backend.yaml" >/dev/null
kc apply -f "$LAB_ROOT/yaml/agentgateway/httproute.yaml" >/dev/null
ok "gateway + backend + route applied"

# ── 3. EnterpriseAgentgatewayPolicy (promptGuard request + response) ──────────
step "Applying EnterpriseAgentgatewayPolicy (promptGuard)"
kc apply -f "$LAB_ROOT/yaml/agentgateway/promptguard-policy.yaml" >/dev/null
ok "promptGuard policy applied"

# ── 4. Wait for the gateway LoadBalancer ──────────────────────────────────────
step "Waiting for gateway LoadBalancer IP"
GW_IP=""
for i in $(seq 1 40); do
  GW_IP="$(kc -n agentgateway-system get svc pii-gateway \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -n "$GW_IP" ]] && break
  sleep 3
done
if [[ -n "$GW_IP" ]]; then
  ok "gateway LB IP: $GW_IP"
else
  warn "gateway IP not yet assigned (continuing — Service DNS still resolves inside the cluster)"
fi

step "Policy ready"
echo "  Inspector UI: kubectl -n pii-demo port-forward svc/inspector-ui 8090:80" >&2
echo "  Gateway:      kubectl -n agentgateway-system port-forward svc/pii-gateway 8080:80" >&2
