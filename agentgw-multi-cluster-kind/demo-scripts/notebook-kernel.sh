#!/usr/bin/env bash
# notebook-kernel.sh — register the **Bash** Jupyter kernel that demo.ipynb uses,
# so Cursor / VS Code can run the shell cells. The notebook's kernelspec is
# `bash`; under a Python kernel every cell fails, and if the kernel's venv was
# deleted you get "Failed to start the Kernel". This recreates the venv and
# re-registers the kernel. Idempotent — safe to re-run.
#
# Run this once per machine, then in Cursor: open demo.ipynb ->
#   Select Kernel (top-right) -> Jupyter Kernel... -> Bash
set -euo pipefail
VENV="${DEMO_VENV:-$HOME/.venvs/bashkernel313}"
PY="$(command -v python3.13 || command -v python3)"
[ -x "$VENV/bin/python" ] || { "$PY" -m venv "$VENV"; "$VENV/bin/pip" install -q --upgrade pip; }
"$VENV/bin/pip" install -q bash_kernel
"$VENV/bin/python" -m bash_kernel.install --user >/dev/null 2>&1

echo "Registered the Bash kernel (venv: $VENV)."
echo "In Cursor: open demo.ipynb -> Select Kernel (top-right) -> Jupyter Kernel... -> Bash"
