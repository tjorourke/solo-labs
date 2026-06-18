#!/usr/bin/env bash
# notebook-kernel.sh — register the **Bash** Jupyter kernel that demo.ipynb uses,
# so Cursor / VS Code can run the shell cells. The notebook's kernelspec is
# `bash`; running it under a Python kernel makes every cell fail. Idempotent.
#
# (Earlier this lab briefly tried a Python/ipykernel wrapper — that was a dead
# end; the real fix for "cells silently fail" was metadata.vscode.languageId on
# each code cell, not the kernel. We register Bash directly now.)
set -euo pipefail
VENV="${DEMO_VENV:-$HOME/.venvs/bashkernel313}"
PY="$(command -v python3.13 || command -v python3)"
[ -x "$VENV/bin/python" ] || { "$PY" -m venv "$VENV"; "$VENV/bin/pip" install -q --upgrade pip; }
"$VENV/bin/pip" install -q bash_kernel
"$VENV/bin/python" -m bash_kernel.install --user >/dev/null 2>&1
# Remove the obsolete Python kernel so it can't be picked by mistake.
"$VENV/bin/python" -m jupyter kernelspec remove -f agentcore-demo >/dev/null 2>&1 || true

echo "Registered the Bash kernel."
echo "In Cursor: open demo.ipynb -> Select Kernel (top-right) -> Jupyter Kernel... -> Bash"
