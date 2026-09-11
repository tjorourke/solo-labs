#!/usr/bin/env bash
# quick.sh: Part 1 of the agent-authoring series, on an existing cluster.
#   ./scripts/quick.sh up        shared platform pieces + the reference agent
#   ./scripts/quick.sh test      the four checks against sre-reference
#   ./scripts/quick.sh teardown  remove the agent and the shared pieces
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
YAML="$SCRIPT_DIR/../yaml"

case "${1:-up}" in
  up)
    bash "$SCRIPT_DIR/platform.sh" up
    step "The reference agent"
    kc apply -f "$YAML/50-reference-agent.yaml" >/dev/null
    wait_agent_ready sre-reference
    ok "sre-reference is Ready"
    cat >&2 <<MSG

  Part 1 is up on $CTX.

    ./scripts/show-card.sh sre-reference
    ./scripts/send-message.sh sre-reference "Which pods in $SRE_NS are unhealthy, and why?"
    ./scripts/stream-message.sh sre-reference "Which pods in $SRE_NS are unhealthy, and why?"
    ./scripts/ask.sh sre-reference "Which pods in $SRE_NS are unhealthy, and why?"
    ./scripts/read-tasks.sh <session id printed by ask.sh>
    ./scripts/check-agent.sh sre-reference
MSG
    ;;
  test) bash "$SCRIPT_DIR/check-agent.sh" sre-reference ;;
  teardown)
    step "Removing the reference agent"
    kc delete -f "$YAML/50-reference-agent.yaml" --ignore-not-found >/dev/null
    bash "$SCRIPT_DIR/platform.sh" teardown
    ;;
  *) echo "Usage: $0 up | test | teardown" >&2; exit 2 ;;
esac
