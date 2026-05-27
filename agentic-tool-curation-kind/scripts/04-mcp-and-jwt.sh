#!/usr/bin/env bash
# 04-mcp-and-jwt.sh — build + kind-load + deploy all the workload services:
#
#   rogue-mcp             — the upstream we're protecting against (10 tools)
#   description-shim      — proxy that swaps tools/list for the curated copy
#   jwt-issuer            — mints jwt-general and jwt-secret-rot Secrets
#   redis                 — backs the ext-auth's chain detection state
#   tool-policy-extauth   — gRPC ext-auth (args + risk + chain)
#   policy-sync           — controller that writes the gateway allow-list
#   curation-inspector-ui — the demo's surface
#
# The curation-manifest ConfigMap is applied BEFORE anything that mounts it
# (description-shim, ext-auth, inspector UI) so pod startup doesn't race.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_secrets

# ── 1. Namespaces + curation manifest ────────────────────────────────────────
step "Creating namespaces and applying the curation manifest"
kc apply -f "$LAB_ROOT/yaml/namespaces/00-namespaces.yaml" >/dev/null
kc apply -f "$LAB_ROOT/yaml/curation/manifest-configmap.yaml" >/dev/null
ok "tool-curation namespace + curation-manifest ConfigMap applied"

# ── 2. Build + load all custom images ────────────────────────────────────────
step "Building + loading custom images into kind"
build_and_load "$LAB_ROOT/src/rogue-mcp"             "$ROGUE_MCP_IMAGE"
build_and_load "$LAB_ROOT/src/description-shim"      "$DESCRIPTION_SHIM_IMAGE"
build_and_load "$LAB_ROOT/src/jwt-issuer"            "$JWT_ISSUER_IMAGE"
build_and_load "$LAB_ROOT/src/policy-sync"           "$POLICY_SYNC_IMAGE"
build_and_load "$LAB_ROOT/src/tool-policy-extauth"   "$TOOL_POLICY_EXTAUTH_IMAGE"
build_and_load "$LAB_ROOT/src/curation-inspector-ui" "$CURATION_INSPECTOR_UI_IMAGE"

# ── 3. Deploy rogue-mcp + description-shim ──────────────────────────────────
step "Deploying rogue-mcp (the upstream)"
kc apply -f "$LAB_ROOT/yaml/rogue-mcp/deployment.yaml" >/dev/null
wait_deploy tool-curation rogue-mcp 120s

step "Deploying description-shim (in front of rogue-mcp)"
kc apply -f "$LAB_ROOT/yaml/description-shim/deployment.yaml" >/dev/null
wait_deploy tool-curation description-shim 120s

# ── 4. Deploy redis ─────────────────────────────────────────────────────────
step "Deploying redis (for ext-auth chain state)"
kc apply -f "$LAB_ROOT/yaml/redis/deployment.yaml" >/dev/null
wait_deploy tool-curation redis 60s

# ── 5. Deploy jwt-issuer ─────────────────────────────────────────────────────
step "Deploying jwt-issuer"
kc apply -f "$LAB_ROOT/yaml/jwt-issuer/serviceaccount.yaml" >/dev/null
kc apply -f "$LAB_ROOT/yaml/jwt-issuer/rbac.yaml" >/dev/null
kc apply -f "$LAB_ROOT/yaml/jwt-issuer/deployment.yaml" >/dev/null
wait_deploy tool-curation jwt-issuer 120s

step "Waiting for issuer to write JWTs + JWKS"
for s in jwt-general jwt-secret-rot; do
  wait_secret tool-curation "$s" 60 || die "jwt-issuer did not create secret $s in 60s"
  ok "secret tool-curation/$s present"
done
end=$(( $(date +%s) + 60 ))
until kc -n tool-curation get configmap jwt-jwks >/dev/null 2>&1; do
  [[ $(date +%s) -ge $end ]] && die "jwt-issuer did not create configmap jwt-jwks in 60s"
  sleep 2
done
ok "configmap tool-curation/jwt-jwks present"

# ── 6. Deploy tool-policy-extauth ───────────────────────────────────────────
step "Deploying tool-policy-extauth (gRPC ext-auth)"
kc apply -f "$LAB_ROOT/yaml/tool-policy-extauth/deployment.yaml" >/dev/null
wait_deploy tool-curation tool-policy-extauth 120s

# ── 7. Deploy curation-inspector-ui ─────────────────────────────────────────
step "Deploying curation-inspector-ui"
kc apply -f "$LAB_ROOT/yaml/curation-inspector-ui/deployment.yaml" >/dev/null
kc apply -f "$LAB_ROOT/yaml/curation-inspector-ui/service.yaml" >/dev/null
wait_deploy tool-curation curation-inspector-ui 180s

step "Workloads ready"
echo "  Next: ./scripts/05-policy-and-sync.sh" >&2
