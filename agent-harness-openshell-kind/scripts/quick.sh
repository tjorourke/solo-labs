#!/usr/bin/env bash
# quick.sh — one-shot orchestrator for the agent-harness-openshell-kind lab.
#
# Usage:
#   ./quick.sh up        — run 01..05 in order (idempotent on rerun)
#   ./quick.sh teardown  — delete the kind cluster
#   ./quick.sh status    — show key resources + the harness condition

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

cmd="${1:-up}"

case "$cmd" in
  up)
    require_secrets
    bash "$SCRIPT_DIR/01-cluster.sh"
    bash "$SCRIPT_DIR/02-openshell.sh"
    bash "$SCRIPT_DIR/03-kagent.sh"
    bash "$SCRIPT_DIR/04-harness.sh"
    bash "$SCRIPT_DIR/05-equip-sandbox.sh"
    bash "$SCRIPT_DIR/06-broken-app.sh"

    echo ""
    cat >&2 <<EOF
══════════════════════════════════════════════════════════════════
  agent-harness-openshell-kind — UP
══════════════════════════════════════════════════════════════════

  Context:  $CTX
  Harness:  kubectl -n kagent get agentharness sre-oncall

  A 'checkout' Deployment is broken on purpose in TWO namespaces:
    incident  (autofix=true) → OpenClaw may fix it
    payments  (no label)     → OpenClaw is denied (403) → escalates to Slack

  Ask OpenClaw to remediate the cluster:

    ./scripts/ask.sh "Triage every namespace for broken workloads. Fix what you are permitted to. If Kubernetes denies a change (403), do NOT force it - post a concise summary to the Slack webhook in /sandbox/.slack-webhook via curl. Summarize what you fixed and what you escalated."

  Watch it work from another terminal:
    kubectl --context $CTX -n incident get pods -w
    kubectl --context $CTX -n payments get pods -w

  kagent dashboard (the harness shows up next to your agents):
    ./scripts/port-forward.sh        # then open http://localhost:8080

  Reset the failure to run it again:
    ./scripts/06-broken-app.sh

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
    for ns in agent-sandbox-system openshell kagent incident; do
      echo "  ─ $ns" >&2
      kc -n "$ns" get pods 2>/dev/null | sed 's/^/    /' >&2 || true
    done

    step "AgentHarness"
    kc -n kagent get agentharness 2>/dev/null | sed 's/^/  /' >&2 || true
    echo "  conditions:" >&2
    kc -n kagent get agentharness sre-oncall -o jsonpath='{.status.conditions}' 2>/dev/null \
      | sed 's/^/    /' >&2 || true
    echo >&2

    step "Incident app"
    kc -n incident get pods -l app=checkout 2>/dev/null | sed 's/^/  /' >&2 || true
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
