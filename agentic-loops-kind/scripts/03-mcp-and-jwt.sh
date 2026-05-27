#!/usr/bin/env bash
# 03-mcp-and-jwt.sh — build + kind-load + deploy all workload services.
#
#   runaway-mcp           — Python MCP with 4 cheap tools
#   redis                 — backs the per-session counters
#   jwt-issuer            — mints jwt-agent + JWKS
#   budget-extauth        — gRPC ext-auth enforcing 4 budgets per session
#   runaway-inspector-ui  — the demo surface
#
# Budgets ConfigMap is applied first so anything that mounts it doesn't
# race on startup.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_secrets

# ── 1. Namespaces + budgets ConfigMap ────────────────────────────────────────
step "Creating namespace and applying the budgets ConfigMap"
kc apply -f "$LAB_ROOT/yaml/namespaces/00-namespaces.yaml" >/dev/null
kc apply -f "$LAB_ROOT/yaml/budgets/budgets-configmap.yaml" >/dev/null
ok "runaway-containment namespace + budgets ConfigMap applied"

# ── 2. Build + load all custom images ────────────────────────────────────────
step "Building + loading custom images into kind"
build_and_load "$LAB_ROOT/src/runaway-mcp"           "$RUNAWAY_MCP_IMAGE"
build_and_load "$LAB_ROOT/src/budget-extauth"        "$BUDGET_EXTAUTH_IMAGE"
build_and_load "$LAB_ROOT/src/jwt-issuer"            "$JWT_ISSUER_IMAGE"
build_and_load "$LAB_ROOT/src/runaway-inspector-ui"  "$RUNAWAY_INSPECTOR_UI_IMAGE"

# ── 3. Deploy runaway-mcp ────────────────────────────────────────────────────
step "Deploying runaway-mcp (the upstream)"
kc apply -f "$LAB_ROOT/yaml/runaway-mcp/deployment.yaml" >/dev/null
wait_deploy runaway-containment runaway-mcp 120s

# ── 4. Deploy redis ─────────────────────────────────────────────────────────
step "Deploying redis (for ext-auth counters)"
kc apply -f "$LAB_ROOT/yaml/redis/deployment.yaml" >/dev/null
wait_deploy runaway-containment redis 60s

# ── 5. Deploy jwt-issuer ─────────────────────────────────────────────────────
step "Deploying jwt-issuer"
kc apply -f "$LAB_ROOT/yaml/jwt-issuer/serviceaccount.yaml" >/dev/null
kc apply -f "$LAB_ROOT/yaml/jwt-issuer/rbac.yaml" >/dev/null
kc apply -f "$LAB_ROOT/yaml/jwt-issuer/deployment.yaml" >/dev/null
wait_deploy runaway-containment jwt-issuer 120s

step "Waiting for issuer to write the JWT + JWKS"
wait_secret runaway-containment jwt-agent 60 || die "jwt-issuer did not create secret jwt-agent in 60s"
ok "secret runaway-containment/jwt-agent present"
end=$(( $(date +%s) + 60 ))
until kc -n runaway-containment get configmap jwt-jwks >/dev/null 2>&1; do
  [[ $(date +%s) -ge $end ]] && die "jwt-issuer did not create configmap jwt-jwks in 60s"
  sleep 2
done
ok "configmap runaway-containment/jwt-jwks present"

# ── 6. Deploy budget-extauth ─────────────────────────────────────────────────
step "Deploying budget-extauth (gRPC ext-auth)"
kc apply -f "$LAB_ROOT/yaml/budget-extauth/deployment.yaml" >/dev/null
wait_deploy runaway-containment budget-extauth 120s

# ── 7. Deploy runaway-inspector-ui ───────────────────────────────────────────
step "Deploying runaway-inspector-ui"
kc apply -f "$LAB_ROOT/yaml/runaway-inspector-ui/deployment.yaml" >/dev/null
wait_deploy runaway-containment runaway-inspector-ui 180s

step "Workloads ready"
echo "  Next: ./scripts/04-policy.sh" >&2
