#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
case "${1:-}" in
  up)
    bash "$LAB/scripts/01-identity.sh"
    bash "$LAB/scripts/02-mesh.sh"
    bash "$LAB/scripts/03-delegation.sh"
    bash "$LAB/scripts/04-vault.sh"
    bash "$LAB/scripts/05-tools.sh"
    bash "$LAB/scripts/capture-refund-revoke.sh"
    bash "$LAB/scripts/03-agents.sh"
    bash "$LAB/scripts/capture-05.sh"
    bash "$LAB/scripts/06-approval.sh"
    bash "$LAB/scripts/capture-rogue.sh"
    bash "$LAB/scripts/capture-kill.sh"
    bash "$LAB/scripts/07-evidence.sh"
    ;;
  test)
    bash "$LAB/scripts/capture-01.sh"
    bash "$LAB/scripts/04-vault.sh"
    bash "$LAB/scripts/capture-03.sh"
    bash "$LAB/scripts/capture-05.sh"
    bash "$LAB/scripts/capture-refund-revoke.sh"
    bash "$LAB/scripts/capture-06.sh"
    bash "$LAB/scripts/capture-rogue.sh"
    bash "$LAB/scripts/capture-kill.sh"
    bash "$LAB/scripts/07-evidence.sh"
    ;;
  teardown)
    for attempt in 1 2 3; do
      kind delete cluster --name trustusbank-lab || true
      if kind get clusters | python3 -c 'import sys;sys.exit("trustusbank-lab" in sys.stdin.read().split())'; then break; fi
      sleep 3
    done
    kind get clusters | python3 -c 'import sys; clusters=sys.stdin.read().split();assert "trustusbank-lab" not in clusters; print("Confirmed: trustusbank-lab absent")'
    ;;
  *) printf 'Usage: bash scripts/quick.sh {up|test|teardown}\n' >&2; exit 2 ;;
esac
