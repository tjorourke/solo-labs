#!/usr/bin/env bash
# 05-scenario.sh — the incident, the shared toolset, and the gateway data path.
#
#   - the broken `checkout` Deployment (ImagePullBackOff) in namespace `incident`
#   - the k8s-ops MCP server (read tools + one mutating patch) scoped to `incident`
#   - the enterprise-agentgateway data path: an Anthropic LLM backend reachable at
#     /v1/chat/completions (OpenAI-compatible -> Claude) and the /mcp route to the
#     k8s-ops server. Every crew built in 06-crews.sh uses these two URLs.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_secrets

step "Namespaces"
kc apply -f "$LAB_ROOT/yaml/namespaces/00-namespaces.yaml" >/dev/null
ok "namespaces applied"

step "Anthropic key Secret for the gateway LLM backend"
# The gateway holds the provider credential; the crews never see it. Key name is
# `Authorization`; agentgateway forwards it to Anthropic as x-api-key.
kc -n agentgateway-system create secret generic anthropic-secret \
  --from-literal=Authorization="${ANTHROPIC_API_KEY}" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
ok "anthropic-secret applied"

step "Building + loading the k8s-ops MCP server image"
build_and_load "$LAB_ROOT/src/k8s-ops" "$K8S_OPS_IMAGE"

step "Deploying the k8s-ops MCP server (RBAC-scoped to 'incident')"
kc apply -f "$LAB_ROOT/yaml/mcp/k8s-ops.yaml" >/dev/null
wait_deploy incident k8s-ops 180s && ok "k8s-ops Available" || warn "k8s-ops not Available in 3m"

step "Gateway data path: LLM backend + routes"
kc apply -f "$LAB_ROOT/yaml/agentgateway/gateway.yaml" >/dev/null
kc apply -f "$LAB_ROOT/yaml/agentgateway/llm-backend.yaml" >/dev/null
kc apply -f "$LAB_ROOT/yaml/agentgateway/routes.yaml" >/dev/null
ok "frameworks-gw + anthropic-llm backend + llm/mcp routes applied"

step "Registering the k8s-ops RemoteMCPServer (for the kagent-native crew)"
kc apply -f "$LAB_ROOT/yaml/mcp/remote-mcp-servers.yaml" >/dev/null
ok "RemoteMCPServer k8s-ops applied"

step "Planting the broken 'checkout' incident"
kc apply -f "$LAB_ROOT/yaml/incident/checkout.yaml" >/dev/null
ok "checkout applied (image nginx:1.27-doesnotexist -> ImagePullBackOff)"

step "Waiting for the gateway to get a LoadBalancer address"
end=$(( $(date +%s) + 120 ))
until [[ -n "$(kc -n agentgateway-system get gateway frameworks-gw -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)" ]]; do
  [[ $(date +%s) -ge $end ]] && { warn "gateway has no address after 2m — check: kc -n agentgateway-system get gateway,pods"; break; }
  sleep 5
done
GW_ADDR="$(kc -n agentgateway-system get gateway frameworks-gw -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)"
[[ -n "$GW_ADDR" ]] && ok "frameworks-gw at ${GW_ADDR}"

step "Scenario ready"
cat >&2 <<EOF
  In-cluster URLs the crews use:
    LLM (OpenAI-compatible):  http://frameworks-gw.agentgateway-system.svc.cluster.local/v1
    MCP tools:                http://frameworks-gw.agentgateway-system.svc.cluster.local/mcp

  Quick checks:
    kc -n incident get pods                 # checkout in ImagePullBackOff
    ./scripts/check-gateway.sh              # raw LLM + MCP call through the gateway

  Next: ./scripts/06-crews.sh
EOF
