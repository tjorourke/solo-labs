#!/usr/bin/env bash
set -euo pipefail
# Dispatches up, test, negative and teardown, plus the individual walkthrough steps.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/lab.py" "${@:-up}"
