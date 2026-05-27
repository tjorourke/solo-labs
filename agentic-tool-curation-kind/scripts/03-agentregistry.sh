#!/usr/bin/env bash
# 03-agentregistry.sh — install agentregistry (OSS by default; Enterprise if
# AR_USE_ENT=1).
#
# The registry's role in this lab is to host the curated MCPServer artifact
# the demo references. The enforcement path (policy-sync + ext-auth +
# description-shim) is driven by the curation-manifest ConfigMap, NOT by
# polling the registry — so even if this script fails to install
# agentregistry, the lab's gateway-side story still works. That's by design:
# we don't want a 3GB enterprise chart pull to gate the rest of the demo.
#
# What the OSS chart needs:
#   - PostgreSQL (we ship a tiny bitnami one alongside)
#
# What the Enterprise chart needs:
#   - same Postgres
#   - GAR auth (gcloud login + helm registry login)
#   - license value (passed via --set)
#
# This script is the most "load-bearing of nothing" piece — if it warns and
# continues, the lab is still demoable. The story page calls this out.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_secrets

NS=agentregistry-system

step "Ensuring namespace $NS"
kc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
EOF
ok "namespace $NS ready"

# ── postgres ─────────────────────────────────────────────────────────────────
#
# We install a small Postgres alongside via the bitnami chart. agentregistry
# needs an external Postgres at minimum; pgvector for semantic search is
# nice-to-have but not load-bearing for the lab demo.
step "Installing bitnami postgresql (sidecar for agentregistry)"
helm --kube-context "$CTX" repo add bitnami https://charts.bitnami.com/bitnami >/dev/null 2>&1 || true
helm --kube-context "$CTX" repo update >/dev/null 2>&1 || true
if ! helm --kube-context "$CTX" -n "$NS" status agentregistry-postgres >/dev/null 2>&1; then
  helm --kube-context "$CTX" upgrade --install agentregistry-postgres \
    bitnami/postgresql \
    --namespace "$NS" --create-namespace \
    --set auth.username=agentregistry \
    --set auth.password=devpassword \
    --set auth.database=agentregistry \
    --set primary.persistence.enabled=false \
    --set primary.resources.requests.cpu=100m \
    --set primary.resources.requests.memory=256Mi \
    --wait --timeout 5m >/dev/null \
    || warn "postgresql install failed — continuing (the lab works without agentregistry)"
fi
ok "postgresql install attempted"

# ── agentregistry ────────────────────────────────────────────────────────────
chart="$AR_OSS_CHART"
version="$AR_OSS_VERSION"
# `set -u` makes empty arrays angry — use a regular string for the (rare)
# enterprise extras and let word-splitting handle it.
extra=""
if [[ "$AR_USE_ENT" == "1" ]]; then
  chart="$AR_ENT_CHART"
  version="$AR_ENT_VERSION"
  step "Authenticating helm OCI to $AGW_GAR_HOST (for enterprise agentregistry chart)"
  ensure_gar_auth "$AGW_GAR_HOST"
  if [[ -n "${AGENTREGISTRY_LICENSE_KEY:-}" ]]; then
    extra="--set license.key=${AGENTREGISTRY_LICENSE_KEY}"
  else
    warn "AR_USE_ENT=1 but AGENTREGISTRY_LICENSE_KEY not set — chart install will likely fail"
  fi
fi

step "Installing agentregistry $version"
log "chart: $chart"
# Disable set -e for this single helm invocation — install best-effort.
set +e
helm_install_with_progress agentregistry "$chart" "$NS" \
  --version "$version" \
  --set postgresql.host=agentregistry-postgres-postgresql."$NS".svc.cluster.local \
  --set postgresql.port=5432 \
  --set postgresql.user=agentregistry \
  --set postgresql.password=devpassword \
  --set postgresql.database=agentregistry \
  $extra \
  --wait --timeout 6m
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
  warn "agentregistry install failed (exit $rc) — continuing"
  warn "the lab's enforcement layers don't depend on the registry being up;"
  warn "the curation-manifest ConfigMap is the actual source of truth."
fi

step "agentregistry install attempted"
echo "  Next: ./scripts/04-mcp-and-jwt.sh" >&2
