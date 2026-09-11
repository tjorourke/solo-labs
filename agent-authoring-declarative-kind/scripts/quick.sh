#!/usr/bin/env bash
# quick.sh: Part 2 of the agent-authoring series, on an existing cluster.
#   ./scripts/quick.sh up        shared platform pieces (Part 1) + the two declarative agents
#   ./scripts/quick.sh test      the four checks against each agent
#   ./scripts/quick.sh teardown  remove this part's agents only
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED="$SCRIPT_DIR/../../agent-authoring-contract-kind/scripts"
[[ -f "$SHARED/lib.sh" ]] || { echo "Part 1 (agent-authoring-contract-kind) must sit next to this lab; it holds the shared scripts." >&2; exit 1; }
# shellcheck source=../../agent-authoring-contract-kind/scripts/lib.sh
source "$SHARED/lib.sh"
YAML="$SCRIPT_DIR/../yaml"
AGENTS=(sre-declarative sre-declarative-go)

case "${1:-up}" in
  up)
    bash "$SHARED/platform.sh" up
    step "The declarative agents"
    local_start=$(date +%s)
    kc apply -f "$YAML/sre-declarative.yaml" -f "$YAML/sre-declarative-go.yaml" >/dev/null
    for a in "${AGENTS[@]}"; do
      wait_agent_ready "$a"
      ok "$a Ready after $(( $(date +%s) - local_start ))s, image $(kc -n "$NS" get pod -l app.kubernetes.io/name="$a" -o jsonpath='{.items[0].spec.containers[0].image}')"
    done
    cat >&2 <<MSG

  Part 2 is up on $CTX.

    $SHARED/show-card.sh sre-declarative
    $SHARED/stream-message.sh sre-declarative "Which pods in $SRE_NS are unhealthy, and why?"
    $SHARED/ask.sh sre-declarative "Which pods in $SRE_NS are unhealthy, and why?"
    ./scripts/quick.sh test
MSG
    ;;
  test) for a in "${AGENTS[@]}"; do bash "$SHARED/check-agent.sh" "$a"; done ;;
  teardown)
    step "Removing this part's agents"
    kc delete -f "$YAML/sre-declarative.yaml" -f "$YAML/sre-declarative-go.yaml" --ignore-not-found >/dev/null
    ok "removed"
    ;;
  *) echo "Usage: $0 up | test | teardown" >&2; exit 2 ;;
esac
