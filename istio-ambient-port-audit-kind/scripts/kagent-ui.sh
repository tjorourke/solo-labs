#!/usr/bin/env bash
# kagent-ui.sh — kagent dashboard at http://localhost:8080. Open it, pick the
# port-audit-reporter agent, and prompt it, e.g.
#   Publish the port audit to tjorourke/solo-port-test at port-audit-report.md on main
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
step "kagent dashboard -> http://localhost:8080  (Ctrl-C to stop)"
exec kc -n kagent port-forward svc/kagent-ui 8080:8080
