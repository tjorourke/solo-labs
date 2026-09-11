#!/usr/bin/env bash
# quick.sh: Part 5 of the agent-authoring series, on an existing cluster.
#   ./scripts/quick.sh up        shared platform pieces, build + push the image, deploy sre-java
#   ./scripts/quick.sh test      the four checks against sre-java
#   ./scripts/quick.sh teardown  remove sre-java (the shared pieces belong to Part 1)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../agent-authoring-contract-kind/scripts/lib.sh
source "$SCRIPT_DIR/../../agent-authoring-contract-kind/scripts/lib.sh"
YAML="$SCRIPT_DIR/../yaml"

case "${1:-up}" in
  up)
    bash "$PART1/scripts/platform.sh" up
    bash "$SCRIPT_DIR/build.sh"
    step "Deploying sre-java"
    kc apply -f "$YAML/sre-java.yaml" >/dev/null
    wait_agent_ready sre-java
    kc -n "$NS" get agent sre-java >&2
    ok "sre-java is Ready"
    cat >&2 <<MSG

  Part 5 is up on $CTX.

    $PART1/scripts/ask.sh sre-java "Which pods in $SRE_NS are unhealthy, and why?"
    ./scripts/quick.sh test
MSG
    ;;
  test) bash "$PART1/scripts/check-agent.sh" sre-java ;;
  teardown)
    step "Removing sre-java"
    kc delete -f "$YAML/sre-java.yaml" --ignore-not-found >/dev/null
    ok "removed"
    ;;
  *) echo "Usage: $0 up | test | teardown" >&2; exit 2 ;;
esac
