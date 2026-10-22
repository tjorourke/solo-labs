#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
case "${1:-}" in
  up)
    bash "$LAB/scripts/01-identity.sh"
    bash "$LAB/scripts/02-mesh.sh"
    bash "$LAB/scripts/10-kagent-enterprise.sh"
    bash "$LAB/scripts/05-platform-tools.sh"
    bash "$LAB/scripts/04-vault.sh"
    bash "$LAB/scripts/08-management.sh"
    bash "$LAB/scripts/11-declarative-agents.sh"
    python3 "$LAB/scripts/client.py" bob 'Reply with only ready. Do not call any tools.'
    ;;
  test)
    python3 -m unittest discover -s "$LAB/scripts" -p 'test_*.py'
    tools
    bash "$LAB/scripts/04-vault.sh"
    python3 "$LAB/scripts/verify.py"
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
