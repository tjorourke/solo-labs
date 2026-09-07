#!/usr/bin/env bash
# quick.sh — the labs-e2e entry point for this lab: build, run, tear down.
#
#   ./scripts/quick.sh up         every stage, skipping what is already done
#   ./scripts/quick.sh teardown   delete the cluster and the weights volume
#   ./scripts/quick.sh status     what exists and what it is costing
#
# READ THIS BEFORE RUNNING IT UNATTENDED. The build brings up a GPU node that
# costs about $5.84/hr, and the cluster still costs roughly $330/month with the
# GPU scaled to zero. `up` therefore arms the nightly scale-to-zero backstop
# before it starts, so an interrupted run cannot leave the GPU billing forever,
# and `teardown` always runs the leftovers check so a partial delete is visible
# rather than silent.
#
# Needs SOVEREIGN_AWS_PROFILE (LAB_AWS_PROFILE or AWS_PROFILE are bridged to it)
# and the Solo licence keys.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# This lab reads SOVEREIGN_AWS_PROFILE, not the LAB_AWS_PROFILE the other AWS labs
# use, so bridge all three rather than making the caller know which.
export LAB_AWS_PROFILE="${LAB_AWS_PROFILE:-${AWS_PROFILE:-${SOVEREIGN_AWS_PROFILE:-}}}"
export AWS_PROFILE="${AWS_PROFILE:-${LAB_AWS_PROFILE:-}}"
export SOVEREIGN_AWS_PROFILE="${SOVEREIGN_AWS_PROFILE:-${AWS_PROFILE:-}}"

[[ -f "${SECRETS_FILE:-}" ]] && { set -a; . "$SECRETS_FILE"; set +a; }

case "${1:-up}" in
  up)
    [[ -n "$SOVEREIGN_AWS_PROFILE" ]] || { echo "quick.sh: set SOVEREIGN_AWS_PROFILE, LAB_AWS_PROFILE or AWS_PROFILE" >&2; exit 2; }
    # Arming BEFORE the build cannot work: gpu-backstop.sh needs the gpu-od
    # nodegroup to exist and refuses with "Arm this after the cluster exists".
    # So arm on EXIT instead, which covers the case that actually matters, a build
    # that dies after the GPU node is up. If the run failed earlier than that
    # there is no nodegroup, arming fails harmlessly, and there is nothing to bill.
    arm_backstop() { bash "$SCRIPT_DIR/gpu-backstop.sh" arm >/dev/null 2>&1 \
      && echo "quick.sh: GPU scale-to-zero backstop armed" \
      || echo "quick.sh: no GPU nodegroup to arm the backstop against" >&2; }
    trap arm_backstop EXIT
    # deploy-all.sh is the lab's documented entry point ("the whole environment,
    # from an empty AWS account ... in one command"). e2e.sh is one of the pieces
    # it calls, the model spine, and it expects the cluster to exist already.
    bash "$SCRIPT_DIR/../deploy-all.sh"
    ;;
  teardown)
    bash "$SCRIPT_DIR/teardown.sh" down || echo "quick.sh: teardown reported a problem" >&2
    # Always report what survived, whether or not the delete claimed success.
    bash "$SCRIPT_DIR/teardown.sh" leftovers || true
    ;;
  status)
    bash "$SCRIPT_DIR/teardown.sh" check
    ;;
  *)
    echo "usage: quick.sh up|teardown|status" >&2; exit 2
    ;;
esac
