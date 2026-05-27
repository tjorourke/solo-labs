#!/usr/bin/env bash
# 04-mcp-and-jwt.sh — build + kind-load + deploy the backend services and the
# inspector UI.
#
#   ops-tools          — Python MCP server (6 tools, single /mcp endpoint)
#   jwt-issuer         — Go: generates RSA keypair + 3 static JWTs at startup,
#                         writes Secrets jwt-{alice,bob,carol} into mcp-rbac
#                         and a ConfigMap with the public JWKS into mcp-rbac.
#   rbac-inspector-ui  — Python+FastAPI+HTMX single-page UI that mounts all
#                         three JWT Secrets and switches identity in the
#                         browser via an "Acting as" dropdown.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_secrets

# ── 1. Build + load images ────────────────────────────────────────────────────
step "Building and loading custom images into kind"
build_and_load "$LAB_ROOT/src/ops-tools"          "$OPS_TOOLS_IMAGE"
build_and_load "$LAB_ROOT/src/jwt-issuer"         "$JWT_ISSUER_IMAGE"
build_and_load "$LAB_ROOT/src/rbac-inspector-ui"  "$RBAC_INSPECTOR_UI_IMAGE"

# ── 2. Namespaces ─────────────────────────────────────────────────────────────
step "Creating namespaces"
kc apply -f "$LAB_ROOT/yaml/namespaces/00-namespaces.yaml" >/dev/null
ok "ops-tools, mcp-rbac namespaces ready"

# ── 3. Deploy ops-tools MCP server ───────────────────────────────────────────
step "Deploying ops-tools MCP server"
kc apply -f "$LAB_ROOT/yaml/ops-tools/deployment.yaml" >/dev/null
wait_deploy ops-tools ops-tools 120s
ok "ops-tools ready"

# ── 4. Deploy jwt-issuer (writes Secrets to mcp-rbac ns) ─────────────────────
step "Deploying jwt-issuer"
kc apply -f "$LAB_ROOT/yaml/jwt-issuer/serviceaccount.yaml" >/dev/null
kc apply -f "$LAB_ROOT/yaml/jwt-issuer/rbac.yaml" >/dev/null
kc apply -f "$LAB_ROOT/yaml/jwt-issuer/deployment.yaml" >/dev/null
wait_deploy mcp-rbac jwt-issuer 120s
ok "jwt-issuer deployment Available"

# Wait for the issuer to actually have written the per-user JWT Secrets and
# the JWKS ConfigMap. The deployment becoming Ready only means the HTTP
# server is up; the issuer does its writes in a startup phase.
step "Waiting for issuer to write JWTs + JWKS"
for s in jwt-alice jwt-bob jwt-carol; do
  wait_secret mcp-rbac "$s" 60 || die "jwt-issuer did not create secret $s in 60s"
  ok "secret mcp-rbac/$s present"
done
# JWKS ConfigMap, used by the EnterpriseAgentgatewayPolicy jwks.remote backendRef.
end=$(( $(date +%s) + 60 ))
until kc -n mcp-rbac get configmap jwt-jwks >/dev/null 2>&1; do
  [[ $(date +%s) -ge $end ]] && die "jwt-issuer did not create configmap jwt-jwks in 60s"
  sleep 2
done
ok "configmap mcp-rbac/jwt-jwks present"

# ── 5. Deploy rbac-inspector-ui ──────────────────────────────────────────────
# Anthropic key Secret (consumed by the UI's Claude calls). Mirrors the
# pattern used by the agentic-pii-guardrail-kind inspector.
step "Creating Anthropic key Secret for the inspector UI"
kc -n mcp-rbac create secret generic rbac-inspector-anthropic \
  --from-literal=ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
ok "rbac-inspector-anthropic secret applied"

step "Deploying rbac-inspector-ui"
kc apply -f "$LAB_ROOT/yaml/rbac-inspector-ui/deployment.yaml" >/dev/null
kc apply -f "$LAB_ROOT/yaml/rbac-inspector-ui/service.yaml"    >/dev/null
wait_deploy mcp-rbac rbac-inspector-ui 180s
ok "rbac-inspector-ui ready"

step "MCP server + JWT issuer + inspector UI ready"
echo "  Next: ./scripts/05-rbac-policy.sh" >&2
