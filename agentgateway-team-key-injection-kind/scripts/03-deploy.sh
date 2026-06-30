#!/usr/bin/env bash
# 03-deploy.sh — build+load mock-idp and echo-upstream, deploy them, create the
# two per-team key Secrets, and apply the two AgentgatewayBackends.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

step "Generating mock-idp signing key (once per clone; gitignored)"
KEY="$LAB_ROOT/src/mock-idp/signing-key.pem"
if [[ -f "$KEY" ]]; then
  ok "signing key already present"
else
  require openssl
  openssl genrsa -out "$KEY" 2048 2>/dev/null
  ok "generated $KEY"
fi

step "Building and loading images"
build_and_load "$LAB_ROOT/src/mock-idp"      "$MOCK_IDP_IMAGE"
build_and_load "$LAB_ROOT/src/echo-upstream" "$ECHO_UPSTREAM_IMAGE"

step "Namespace + services (mock-idp, echo-upstream)"
kc apply -f "$LAB_ROOT/yaml/namespaces/00-namespaces.yaml" >/dev/null
kc apply -f "$LAB_ROOT/yaml/services/mock-idp.yaml" >/dev/null
kc apply -f "$LAB_ROOT/yaml/services/echo-upstream.yaml" >/dev/null
wait_deploy teamkey-demo mock-idp 120s
wait_deploy teamkey-demo echo-upstream 120s
ok "idp + echo ready"

step "Creating per-team static-key Secrets (in agentgateway-system)"
# The Secret's Authorization key is the value agentgateway injects upstream.
kc -n agentgateway-system create secret generic sales-secret \
  --from-literal=Authorization="${SALES_KEY}" --dry-run=client -o yaml | kc apply -f - >/dev/null
kc -n agentgateway-system create secret generic engineering-secret \
  --from-literal=Authorization="${ENGINEERING_KEY}" --dry-run=client -o yaml | kc apply -f - >/dev/null
ok "sales-secret + engineering-secret applied"

step "Applying AgentgatewayBackends (one per team)"
kc apply -f "$LAB_ROOT/yaml/backends/team-sales.yaml" >/dev/null
kc apply -f "$LAB_ROOT/yaml/backends/team-engineering.yaml" >/dev/null
ok "team-sales + team-engineering backends applied"

step "Deploy done"
echo "  Next: ./scripts/04-policy.sh" >&2
