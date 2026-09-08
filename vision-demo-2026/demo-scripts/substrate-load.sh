#!/usr/bin/env bash
# substrate-load.sh — fill the Substrate Scope board: deploy N agents and drive B real
# chats at them. A thin wrapper over `substrate-scope.sh load`, so it takes the same two
# arguments and defaults to 6 agents / 40 chats.
#
# Runs from anywhere, because it resolves the sibling script from its OWN location
# rather than from the current directory:
#
#   ./demo-scripts/substrate-load.sh          # from the suite root
#   ./substrate-load.sh                       # from demo-scripts/
#   ./demo-scripts/substrate-load.sh 10 60    # 10 agents, 60 chats
#
# The chats are REAL model calls. The budget is the stop: it sends B and then flips the
# visualiser's demo switch back off.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCOPE="$SCRIPT_DIR/substrate-scope.sh"
[ -x "$SCOPE" ] || { echo "✗ cannot find an executable substrate-scope.sh next to this script ($SCOPE)"; exit 1; }
exec "$SCOPE" load "${1:-6}" "${2:-40}"
