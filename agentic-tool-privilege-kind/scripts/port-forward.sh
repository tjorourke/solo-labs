#!/usr/bin/env bash
# port-forward.sh — kagent dashboard at http://localhost:8080
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
step "kagent dashboard -> http://localhost:8080  (Ctrl-C to stop)"
exec kc -n kagent port-forward svc/kagent-ui 8080:80
