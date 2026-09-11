#!/usr/bin/env bash
# quick.sh: Part 3 of the agent-authoring series, on an existing cluster.
#   ./scripts/quick.sh up        shared platform pieces (Part 1), build, push, deploy sre-python
#   ./scripts/quick.sh test      the four checks against sre-python
#   ./scripts/quick.sh teardown  remove sre-python (the shared pieces stay)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../agent-authoring-contract-kind/scripts/lib.sh
source "$SCRIPT_DIR/../../agent-authoring-contract-kind/scripts/lib.sh"
YAML="$SCRIPT_DIR/../yaml"

case "${1:-up}" in
  up)
    bash "$PART1/scripts/platform.sh" up
    bash "$SCRIPT_DIR/build.sh"
    step "Deploying sre-python"
    kc apply -f "$YAML/sre-python.yaml" >/dev/null
    wait_agent_ready sre-python
    ok "sre-python is Ready"
    cat >&2 <<MSG

  Part 3 is up on $CTX.

    ../agent-authoring-contract-kind/scripts/show-card.sh sre-python
    ../agent-authoring-contract-kind/scripts/stream-message.sh sre-python "Which pods in $SRE_NS are unhealthy, and why?"
    ../agent-authoring-contract-kind/scripts/ask.sh sre-python "Which pods in $SRE_NS are unhealthy, and why?"
    ./scripts/quick.sh test
MSG
    ;;
  test) bash "$PART1/scripts/check-agent.sh" sre-python ;;
  teardown)
    step "Removing sre-python"
    kc delete -f "$YAML/sre-python.yaml" --ignore-not-found >/dev/null
    ok "removed"
    ;;
  *) echo "Usage: $0 up | test | teardown" >&2; exit 2 ;;
esac
