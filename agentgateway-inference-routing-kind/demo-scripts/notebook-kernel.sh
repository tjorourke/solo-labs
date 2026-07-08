#!/usr/bin/env bash
# notebook-kernel.sh — register the **Bash** Jupyter kernel that demo.ipynb uses,
# so Cursor / VS Code can run the shell cells. The notebook's kernelspec is
# `bash`; under a Python kernel every cell fails.
#
# "Failed to start the Kernel" with `spawn .../bin/python ENOENT` means the
# kernel's venv is gone or its python symlink dangles (e.g. it pointed at a
# python3.NN that was later removed). This rebuilds the venv with a python that
# actually runs and re-registers the kernel. Idempotent — safe to re-run.
#
# After running, in Cursor: open demo.ipynb -> Select Kernel (top-right) ->
#   Jupyter Kernel... -> Bash. If a cell already failed, reload the window first
#   (Cmd+Shift+P -> "Developer: Reload Window") so Cursor drops the dead kernel.
set -euo pipefail
VENV="${DEMO_VENV:-$HOME/.venvs/bashkernel313}"
PY="$(command -v python3.13 || command -v python3.12 || command -v python3)"
[ -n "$PY" ] || { echo "no python3 on PATH — install Python first" >&2; exit 1; }

# Recreate the venv unless its python actually EXECUTES (a dangling symlink is
# -x true but fails to run, which is exactly the ENOENT case Cursor reports).
if ! "$VENV/bin/python" -c 'pass' >/dev/null 2>&1; then
  echo "creating venv $VENV (python: $PY)"
  rm -rf "$VENV"
  "$PY" -m venv "$VENV"
  "$VENV/bin/python" -m pip install -q --upgrade pip
fi

"$VENV/bin/pip" install -q bash_kernel
"$VENV/bin/python" -m bash_kernel.install --user >/dev/null 2>&1

# Sanity: the exact command Cursor will spawn must import cleanly.
"$VENV/bin/python" -c 'import bash_kernel' \
  && echo "Registered the Bash kernel (venv: $VENV) — verified." \
  || { echo "bash_kernel still not importable from $VENV" >&2; exit 1; }
echo "In Cursor: Select Kernel (top-right) -> Jupyter Kernel... -> Bash  (reload the window if a cell already failed)."
