#!/usr/bin/env bash
# port-forward.sh — expose the kagent dashboard on http://localhost:8080.
# Leave running in its own terminal.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

step "kagent dashboard → http://localhost:8080"
echo "  Ctrl-C to stop." >&2
exec kc -n kagent port-forward svc/kagent-ui 8080:8080
