#!/usr/bin/env bash
# 04-llm-and-jwt.sh — build + kind-load + deploy the two backend services.
#
#   mock-llm     — Python OpenAI-compatible /v1/chat/completions with realistic
#                  usage{prompt,completion,total}_tokens fields
#   jwt-issuer   — Go: generates RSA keypair + 2 static JWTs at startup
#                  (sub=dba, sub=support), writes Secrets jwt-{dba,support}
#                  into the kagent ns and JWKS ConfigMap into agentgateway-system.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

# ── 1. Build + load images ────────────────────────────────────────────────────
step "Building and loading custom images into kind"
build_and_load "$LAB_ROOT/src/mock-llm"   "$MOCK_LLM_IMAGE"
build_and_load "$LAB_ROOT/src/jwt-issuer" "$JWT_ISSUER_IMAGE"

# ── 2. Namespaces ─────────────────────────────────────────────────────────────
step "Creating namespaces"
kc apply -f "$LAB_ROOT/yaml/namespaces/00-namespaces.yaml" >/dev/null
ok "llm, budgets namespaces ready"

# ── 3. Deploy mock LLM ────────────────────────────────────────────────────────
step "Deploying mock LLM"
kc apply -f "$LAB_ROOT/yaml/mock-llm/deployment.yaml" >/dev/null
wait_deploy llm mock-llm 120s
ok "mock-llm ready"

# ── 4. Deploy jwt-issuer (writes Secrets to kagent ns) ───────────────────────
step "Deploying jwt-issuer"
kc apply -f "$LAB_ROOT/yaml/jwt-issuer/serviceaccount.yaml" >/dev/null
kc apply -f "$LAB_ROOT/yaml/jwt-issuer/rbac.yaml" >/dev/null
kc apply -f "$LAB_ROOT/yaml/jwt-issuer/deployment.yaml" >/dev/null
wait_deploy budgets jwt-issuer 120s
ok "jwt-issuer deployment Available"

# Wait for the issuer to actually have written the per-team JWT Secrets and
# the JWKS ConfigMap. The deployment becoming Ready only means the HTTP
# server is up; the issuer does its writes in a startup phase.
step "Waiting for issuer to write JWTs + JWKS"
for s in jwt-dba jwt-support; do
  wait_secret kagent "$s" 60 || die "jwt-issuer did not create secret $s in 60s"
  ok "secret kagent/$s present"
done
# JWKS ConfigMap, used by the EnterpriseAgentgatewayPolicy jwks.remote backendRef.
end=$(( $(date +%s) + 60 ))
until kc -n budgets get configmap jwt-jwks >/dev/null 2>&1; do
  [[ $(date +%s) -ge $end ]] && die "jwt-issuer did not create configmap jwt-jwks in 60s"
  sleep 2
done
ok "configmap budgets/jwt-jwks present"

step "Mock LLM + JWT issuer ready"
echo "  Next: ./scripts/05-budgets.sh" >&2
