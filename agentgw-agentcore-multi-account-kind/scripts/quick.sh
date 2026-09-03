#!/usr/bin/env bash
# quick.sh — one-shot orchestrator.
#   up        provision AWS (tofu) + kind platform + runtimes + agents + gateway config + invoke
#   teardown  delegate to teardown.sh: runtimes, log groups, execution roles,
#             S3 source bundles, tofu destroy, kind, the published GitHub repo
#   status    what's running where
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

usage(){ echo "usage: $0 up|teardown|status" >&2; exit 1; }

case "${1:-}" in
  up)
    require_secrets
    "$SCRIPT_DIR/10-tofu.sh"
    "$SCRIPT_DIR/20-cluster.sh"
    "$SCRIPT_DIR/21-keycloak.sh"
    "$SCRIPT_DIR/22-agentgateway.sh"
    "$SCRIPT_DIR/23-ingress.sh"
    "$SCRIPT_DIR/24-agentregistry.sh"
    "$SCRIPT_DIR/30-runtimes.sh"
    "$SCRIPT_DIR/33-model-access.sh"
    "$SCRIPT_DIR/31-agents.sh"
    "$SCRIPT_DIR/32-wait-runtimes.sh"
    "$SCRIPT_DIR/40-gateway-config.sh"
    "$SCRIPT_DIR/41-invoke.sh"
    step "Lab is up"
    echo "  AgentRegistry : http://${AR_HOST}" >&2
    echo "  Agents        : http://${AGENTS_HOST}/portfolio-{a,b}/{poet,quant}" >&2
    echo "  Evidence      : PROFILE_A=... PROFILE_B=... ./scripts/50-cloudtrail.sh" >&2
    ;;
  teardown)
    # The real implementation lives in teardown.sh: it has to delete the
    # non-tofu artefacts (runtimes, log groups, SDK execution roles, S3 source
    # bundles) BEFORE tofu destroy removes the only credentials that can reach
    # them, and it verifies the accounts afterwards instead of assuming.
    exec "$SCRIPT_DIR/teardown.sh"
    ;;
  status)
    kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME" && ok "kind cluster '$CLUSTER_NAME' running" || warn "kind cluster not running"
    kc -n "$GW_NS" get gateway "$GW_NAME" 2>/dev/null | sed 's/^/  /' >&2 || true
    ARCTL_API_BASE_URL="$ARCTL_API_BASE_URL" arctl get deployments 2>/dev/null | sed 's/^/  /' >&2 || true
    [[ -f "$LAB_ROOT/deploy/.env.runtimes" ]] && sed 's/=.*arn/=arn/; s/^/  /' "$LAB_ROOT/deploy/.env.runtimes" >&2 || true
    ;;
  *) usage ;;
esac
