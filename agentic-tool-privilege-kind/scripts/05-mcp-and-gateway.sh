#!/usr/bin/env bash
# 05-mcp-and-gateway.sh — the mock-db MCP server, the agentgateway data plane
# that fronts it, and the two agent identity tokens.
#
# All the shape lives in YAML (yaml/mock-db, yaml/agentgateway). The only thing
# that cannot be static is the two agent tokens: they are minted live from
# Keycloak and written as Secrets (as the full "Bearer <token>" header value)
# that the RemoteMCPServers inject.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_secrets
check_docker

step "Building + loading the mock-db MCP server image"
build_and_load "$LAB_ROOT/images/mock-db" "$MOCK_DB_IMAGE"
ok "$MOCK_DB_IMAGE loaded into kind"

step "Deploying mock-db (simulated Postgres, starts locked)"
kc apply -f "$LAB_ROOT/yaml/mock-db/deployment.yaml" >/dev/null
wait_deploy mock-db mock-db 180s && ok "mock-db running" || warn "mock-db not Available"

step "Applying the agentgateway data plane + policies"
kc apply -f "$LAB_ROOT/yaml/agentgateway/gateway.yaml" >/dev/null
kc apply -f "$LAB_ROOT/yaml/agentgateway/backend-route.yaml" >/dev/null
kc apply -f "$LAB_ROOT/yaml/agentgateway/jwt-policy.yaml" >/dev/null
kc apply -f "$LAB_ROOT/yaml/agentgateway/mcp-authz-policy.yaml" >/dev/null
ok "Gateway + AgentgatewayBackend + JWT auth + MCP tool authz applied"
log "waiting for the gateway data plane to be programmed..."
kc -n agentgateway-system rollout status deploy/db-gateway --timeout=180s >/dev/null 2>&1 \
  && ok "db-gateway data plane ready" || warn "db-gateway deploy not ready yet (check: kc -n agentgateway-system get pods)"

step "Minting the two agent identity tokens from Keycloak"
# db-reader identity for the diagnoser, db-operator for the remediator. Stored as
# the full Authorization header value so RemoteMCPServer headersFrom injects it verbatim.
for pair in "agent-diagnoser:agent-token-reader" "agent-remediator:agent-token-operator"; do
  user="${pair%%:*}"; secret="${pair##*:}"
  tok="$(mint_keycloak_token "$user")"
  [[ -n "$tok" ]] || die "could not mint Keycloak token for $user"
  kc -n kagent create secret generic "$secret" \
    --from-literal=authorization="Bearer ${tok}" \
    --dry-run=client -o yaml | kc apply -f - >/dev/null
  ok "secret kagent/$secret minted for $user"
done

step "MCP server + gateway + tokens ready"; echo "  Next: ./scripts/06-agents.sh" >&2
