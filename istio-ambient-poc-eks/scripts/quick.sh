#!/usr/bin/env bash
# quick.sh — the labs-e2e entry point for this lab: provision, run, tear down.
#
#   ./scripts/quick.sh up         tofu apply, then every stage in order
#   ./scripts/quick.sh teardown   delete the NLBs, then tofu destroy
#   ./scripts/quick.sh status     what exists right now
#
# This lab builds REAL AWS infrastructure (two EKS clusters, a VM, NLBs) and it
# costs money for as long as it is up. `teardown` is not optional, and the
# harness always calls it. If a run is interrupted, run teardown by hand and then
# `status` to confirm nothing survived.
#
# Needs LAB_AWS_PROFILE and SOLO_ISTIO_LICENSE_KEY (or SECRETS_FILE).

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TOFU_DIR="$LAB_ROOT/tofu"

# The harness exports AWS_PROFILE; the lab scripts read LAB_AWS_PROFILE. Bridge
# the two so a run works either way round without the caller having to know.
export LAB_AWS_PROFILE="${LAB_AWS_PROFILE:-${AWS_PROFILE:-}}"
export AWS_PROFILE="${AWS_PROFILE:-${LAB_AWS_PROFILE:-}}"

[[ -f "${SECRETS_FILE:-}" ]] && { set -a; . "$SECRETS_FILE"; set +a; }

tofu_bin() { command -v tofu >/dev/null 2>&1 && echo tofu || echo terraform; }

case "${1:-up}" in
  up)
    [[ -n "$LAB_AWS_PROFILE" ]] || { echo "quick.sh: set LAB_AWS_PROFILE or AWS_PROFILE" >&2; exit 2; }
    TF="$(tofu_bin)"
    echo "==> Provisioning the EKS clusters ($TF apply)"
    "$TF" -chdir="$TOFU_DIR" init -input=false >/dev/null
    "$TF" -chdir="$TOFU_DIR" apply -auto-approve -input=false
    echo "==> Running every stage"
    bash "$SCRIPT_DIR/run-all.sh"
    ;;
  teardown)
    # Never let a teardown failure stop the harness from trying the rest: an
    # orphaned NLB is cheap, an orphaned EKS cluster is not, so always reach
    # tofu destroy even if the Service deletion pass had a problem.
    bash "$SCRIPT_DIR/teardown.sh" || {
      echo "quick.sh: teardown.sh failed, forcing $(tofu_bin) destroy" >&2
      "$(tofu_bin)" -chdir="$TOFU_DIR" destroy -auto-approve -input=false
    }
    ;;
  status)
    "$(tofu_bin)" -chdir="$TOFU_DIR" state list 2>/dev/null || echo "no state"
    ;;
  *)
    echo "usage: quick.sh up|teardown|status" >&2; exit 2
    ;;
esac
