#!/usr/bin/env bash
# quick.sh — one-shot orchestrator for agent-harness-openclaw-kind.
#
#   ./scripts/quick.sh up         kind + Agent Substrate + kagent + OpenClaw AgentHarness,
#                                 then agentgateway for the model path and the MCP tool path
#   ./scripts/quick.sh baseline   exact OpenClaw 2.0 (v2026.8.1) in Docker, plus its five tests
#   ./scripts/quick.sh test       the PASS/FAIL table (scripts/check.sh)
#   ./scripts/quick.sh status     harness, template, actors and workers
#   ./scripts/quick.sh ui         port-forward the kagent UI
#   ./scripts/quick.sh teardown   delete the kind cluster and the Docker baseline
#
# Needs: docker, kind, kubectl, helm, python3, git; ANTHROPIC_API_KEY in the environment
# (or in $SECRETS_FILE). Roughly 8 vCPU / 16 GB free for the Substrate stack.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

cmd="${1:-up}"
case "$cmd" in
  up)
    require_secrets
    bash "$SCRIPT_DIR/01-cluster.sh"
    bash "$SCRIPT_DIR/02-substrate.sh"
    bash "$SCRIPT_DIR/03-kagent.sh"
    bash "$SCRIPT_DIR/04-harness.sh"
    bash "$SCRIPT_DIR/05-agentgateway.sh"
    bash "$SCRIPT_DIR/06-mcp.sh"
    kc apply -f "$YAML/30-reference-sandbox-agent.yaml" >/dev/null
    cat >&2 <<MSG

══════════════════════════════════════════════════════════════════
  agent-harness-openclaw-kind — UP
══════════════════════════════════════════════════════════════════

  Context:   $CTX
  Harness:   kubectl --context $CTX -n kagent get agentharness $HARNESS
  Template:  kubectl --context $CTX -n kagent get actortemplates.ate.dev

  Ask OpenClaw (ACP through the kagent controller):
    ./scripts/ask.sh "Which pods in sre-lab are unhealthy, and why? Do not make changes."

  kagent UI:   ./scripts/quick.sh ui    then http://localhost:${UI_PORT}
  Checks:      ./scripts/quick.sh test
  Baseline:    ./scripts/quick.sh baseline   (OpenClaw 2.0 alone, in Docker)
MSG
    ;;
  baseline)
    require_secrets
    bash "$SCRIPT_DIR/00-baseline.sh"
    export CAPTURES WORKSPACE="$RUNTIME/openclaw/workspace" TOKEN
    TOKEN="$(<"$RUNTIME/openclaw/gateway-token")"
    python3 "$SCRIPT_DIR/baseline-test.py" all
    python3 "$SCRIPT_DIR/approval-test.py"
    ;;
  test)
    bash "$SCRIPT_DIR/check.sh"
    ;;
  status)
    kc -n "$NS" get agentharness,sandboxagents 2>/dev/null || true
    kc -n "$NS" get actortemplates.ate.dev,workerpools.ate.dev 2>/dev/null || true
    substrate_status | python3 -c '
import sys, json
d = json.load(sys.stdin)["data"]
print("  %-10s %-4s %-44s %s" % ("STATE", "VER", "ACTOR", "TEMPLATE"))
for a in sorted(d["actors"], key=lambda a: a["actorId"]):
    print("  %-10s v%-3s %-44s %s" % (a["status"], a["version"], a["actorId"][:44], a["actorTemplateName"]))
print("  %d actors, %d workers" % (len(d["actors"]), len(d["workers"])))' 2>/dev/null || true
    ;;
  ui)
    __start_pf svc/kagent-ui "$UI_PORT" 8080 "http://127.0.0.1:${UI_PORT}/" && ok "kagent UI: http://localhost:${UI_PORT}"
    ;;
  teardown)
    pf_down
    bash "$SCRIPT_DIR/00-baseline.sh" down || true
    if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
      kind delete cluster --name "$CLUSTER_NAME"
    fi
    ok "torn down"
    ;;
  *)
    echo "Usage: $0 up | baseline | test | status | ui | teardown" >&2
    exit 2
    ;;
esac
