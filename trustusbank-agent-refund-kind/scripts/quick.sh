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
    bash "$LAB/scripts/wake.sh"
    ;;
  wake) bash "$LAB/scripts/wake.sh" ;;
  test)
    python3 -m unittest discover -s "$LAB/scripts" -p 'test_*.py'
    tools
    bash "$LAB/scripts/04-vault.sh"
    python3 "$LAB/scripts/verify.py"
    ;;
  teardown)
    [[ "$CTX" == kind-trustusbank-lab ]] || { printf 'Refusing to delete an unexpected cluster\n' >&2; exit 1; }
    kind delete cluster --name trustusbank-lab
    kind get clusters | python3 -c 'import sys; assert "trustusbank-lab" not in sys.stdin.read().split(); print("Confirmed: standalone trustusbank-lab absent")'
    ;;
  *) printf 'Usage: bash scripts/quick.sh {up|wake|test|teardown}\n' >&2; exit 2 ;;
esac
