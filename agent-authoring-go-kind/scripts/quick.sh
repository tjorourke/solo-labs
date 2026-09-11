#!/usr/bin/env bash
# quick.sh: Part 4 of the agent-authoring series, on an existing cluster.
#   ./scripts/quick.sh up        shared platform pieces (Part 1) + build, push and deploy sre-go
#   ./scripts/quick.sh test      the four checks against sre-go
#   ./scripts/quick.sh teardown  remove the agent (the shared pieces stay for the other parts)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../agent-authoring-contract-kind/scripts/lib.sh
source "$SCRIPT_DIR/../../agent-authoring-contract-kind/scripts/lib.sh"
# lib.sh exports PART1, the Part 1 lab directory; its scripts are shared by the series.
SHARED="$PART1/scripts"
YAML="$SCRIPT_DIR/../yaml"

case "${1:-up}" in
  up)
    bash "$SHARED/platform.sh" up
    bash "$SCRIPT_DIR/build.sh"
    step "Deploying sre-go"
    kc apply -f "$YAML/sre-go.yaml" >/dev/null
    # A re-run after a rebuild: the tag is unchanged, so make the pod pull again.
    kc -n "$NS" rollout restart deploy/sre-go >/dev/null 2>&1 || true
    wait_agent_ready sre-go
    ok "sre-go is Ready"
    cat >&2 <<MSG

  Part 4 is up on $CTX.

    $SHARED/show-card.sh sre-go
    $SHARED/ask.sh sre-go "Which pods in $SRE_NS are unhealthy, and why?"
    ./scripts/quick.sh test
MSG
    ;;
  test) bash "$SHARED/check-agent.sh" sre-go ;;
  teardown)
    step "Removing sre-go"
    kc delete -f "$YAML/sre-go.yaml" --ignore-not-found >/dev/null
    ok "removed"
    ;;
  *) echo "Usage: $0 up | test | teardown" >&2; exit 2 ;;
esac
