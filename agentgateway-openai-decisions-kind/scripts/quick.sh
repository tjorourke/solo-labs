#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in
  up) exec bash scripts/up.sh ;;
  test) exec python3 scripts/test.py ;;
  teardown)
    if [[ "${CONFIRM_TEARDOWN:-}" != openai-decisions ]]; then
      echo 'Only after review: CONFIRM_TEARDOWN=openai-decisions ./scripts/quick.sh teardown' >&2
      exit 1
    fi
    kind delete cluster --name openai-decisions ;;
  *) echo 'Usage: ./scripts/quick.sh {up|test|teardown}' >&2; exit 2 ;;
esac
