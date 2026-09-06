#!/usr/bin/env bash
# quick.sh — one command to run the whole lab, the same entrypoint name every
# lab in this repo uses so the E2E harness and a reader find it in the same
# place. The lab itself lives in scripts/e2e.sh; this only forwards to it.
#
#   ./scripts/quick.sh                          # run everything, with assertions
#   ./scripts/quick.sh SECRETS_FILE=/path/...   # args pass straight through
#
# Versions come from the repo-wide versions.env matrix (scripts/lib.sh sources
# it), so bumping versions.json re-runs this lab on the new versions.
# Teardown: kind delete cluster --name cert-identity
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/e2e.sh" "$@"
