#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  up)
    echo "KB-only: nothing to deploy"
    ;;
  teardown)
    echo "KB-only: nothing to teardown"
    ;;
  *)
    echo "usage: $0 {up|teardown}" >&2
    exit 2
    ;;
esac
