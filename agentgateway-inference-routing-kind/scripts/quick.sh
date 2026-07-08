#!/usr/bin/env bash
# quick.sh — one-shot orchestrator for agentgateway-inference-routing-kind.
#
#   ./quick.sh up         run 01..04 in order (idempotent)
#   ./quick.sh teardown   delete the kind cluster
#   ./quick.sh status     show the routing resources
#   ./quick.sh test       fire requests and show which replica the EPP picked
#
# Enterprise by default (needs AGENTGATEWAY_LICENSE_KEY). OSS path:
#   AGW_EDITION=oss ./quick.sh up
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

cmd="${1:-up}"
case "$cmd" in
  up)
    require_secrets
    bash "$SCRIPT_DIR/01-cluster.sh"
    bash "$SCRIPT_DIR/02-agentgateway.sh"
    bash "$SCRIPT_DIR/03-model-servers.sh"
    bash "$SCRIPT_DIR/04-inference-pool.sh"
    step "Up. Reach it:"
    log "./demo-scripts/port-forward.sh   # then: curl localhost:18080/v1/chat/completions ..."
    log "./scripts/quick.sh test          # see the endpoint picker route to the cold replica"
    ;;
  teardown)
    step "Deleting kind cluster '$CLUSTER_NAME'"
    kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 || true
    ok "cluster deleted"
    ;;
  status)
    kc -n "$NS" get inferencepool,inferenceobjective,gateway,httproute 2>&1
    echo
    kc -n "$NS" get pods -l app=vllm-sim -o wide 2>&1
    kc -n "$NS" get deploy vllm-sim-epp 2>&1
    ;;
  test)
    bash "$SCRIPT_DIR/../demo-scripts/route-test.sh" "${2:-8}"
    ;;
  *)
    die "unknown command '$cmd' (up|teardown|status|test)"
    ;;
esac
