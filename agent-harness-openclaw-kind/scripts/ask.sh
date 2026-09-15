#!/usr/bin/env bash
# ask.sh — send one prompt to the OpenClaw harness through kagent over ACP.
#   ./scripts/ask.sh "Which pods in sre-lab are unhealthy, and why?"
#   ./scripts/ask.sh --approve "Run uname -a"          # allow-once any permission request
#   HARNESS=other-harness ./scripts/ask.sh "..."        # a different AgentHarness
# Extra flags before the prompt go to acp.py (--approve, --capture NAME, --session ID, --quiet).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
[[ $# -ge 1 ]] || die "usage: $0 [--approve] [--capture NAME] \"prompt\""
controller_pf
exec python3 "$SCRIPT_DIR/acp.py" --agent "$HARNESS" --namespace "$NS" --url "$CONTROLLER_URL" "$@"
