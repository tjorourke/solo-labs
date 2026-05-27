#!/usr/bin/env bash
# quick.sh — one-shot orchestrator for the agentic-tool-curation-kind lab.
#
# Usage:
#   ./quick.sh up        — run 01..05 in order (idempotent on rerun)
#   ./quick.sh teardown  — delete the kind cluster
#   ./quick.sh status    — show key resources + URLs

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

cmd="${1:-up}"

case "$cmd" in
  up)
    require_secrets
    bash "$SCRIPT_DIR/01-cluster.sh"
    bash "$SCRIPT_DIR/02-agentgateway.sh"
    bash "$SCRIPT_DIR/03-agentregistry.sh"
    bash "$SCRIPT_DIR/04-mcp-and-jwt.sh"
    bash "$SCRIPT_DIR/05-policy-and-sync.sh"

    echo ""
    cat >&2 <<EOF
══════════════════════════════════════════════════════════════════
  agentic-tool-curation-kind — UP
══════════════════════════════════════════════════════════════════

  Context:  $CTX
  Next:     ./scripts/port-forward.sh
            then open http://localhost:8090 — the Curation Inspector UI.

            Click each of the four attack buttons to demonstrate one
            enforcement layer in turn:
              1. Deny-by-default (gateway CEL allow-list)
              2. Args schema validation (ext-auth)
              3. Risk-tier × intent (ext-auth)
              4. Forbidden chain (ext-auth + Redis)

  Teardown:
    ./scripts/quick.sh teardown
EOF
    ;;

  teardown)
    step "Deleting kind cluster '$CLUSTER_NAME'"
    if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
      kind delete cluster --name "$CLUSTER_NAME"
      ok "cluster '$CLUSTER_NAME' deleted"
    else
      log "cluster '$CLUSTER_NAME' not present — nothing to do"
    fi
    ;;

  status)
    step "Cluster"
    kc cluster-info 2>/dev/null | head -2 || die "cluster not reachable (is it up?)"

    step "Key deployments"
    for ns in agentgateway-system agentregistry-system tool-curation; do
      echo "  ─ $ns" >&2
      kc -n "$ns" get deploy 2>/dev/null | tail -n +1 | sed 's/^/    /' >&2 || true
    done

    step "Gateway IP"
    GW_IP="$(kc -n agentgateway-system get svc curation-gateway \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    [[ -n "$GW_IP" ]] && echo "  http://$GW_IP" >&2 || echo "  (gateway IP not yet assigned)" >&2

    step "Inspector UI"
    kc -n tool-curation get deploy curation-inspector-ui 2>/dev/null | sed 's/^/  /' >&2 || true

    step "Current allow-list (from EnterpriseAgentgatewayPolicy)"
    kc -n tool-curation get enterpriseagentgatewaypolicy mcp-tool-allowlist \
      -o jsonpath='{.spec.backend.mcp.authorization.policy.matchExpressions}' 2>/dev/null | sed 's/^/  /' >&2 || true
    ;;

  *)
    cat >&2 <<EOF
Usage:
  $0 up        — bring up the full lab
  $0 teardown  — delete the kind cluster
  $0 status    — show key resources

EOF
    exit 2
    ;;
esac
