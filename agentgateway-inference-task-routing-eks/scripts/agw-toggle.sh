#!/usr/bin/env bash
# Switch terminal Claude Code AND the macOS Claude Desktop app.
# on/off handle the managed plist, saved Desktop mode and an automatic app restart.
# Existing terminal Claude Code sessions still need restarting.
# --install writes a launcher to ~/Downloads pointing at this lab's implementation.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_DIR="${LAB_DIR:-$HERE}"
export LAB_DIR
exec python3 "$LAB_DIR/scripts/agw-toggle.py" "$@"
