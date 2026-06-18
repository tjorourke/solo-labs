#!/usr/bin/env bash
# notebook-kernel.sh — register the Python kernel demo.ipynb uses so Cursor/VS
# Code can run it. The notebook is shell commands run with `!` under a Python
# kernel, because Cursor launches Python (ipykernel) reliably but botches raw
# Bash-kernel launches. Idempotent.
set -euo pipefail
VENV="${DEMO_VENV:-$HOME/.venvs/bashkernel313}"
PY="$(command -v python3.13 || command -v python3)"
[ -x "$VENV/bin/python" ] || { "$PY" -m venv "$VENV"; "$VENV/bin/pip" install -q --upgrade pip; }
"$VENV/bin/pip" install -q ipykernel
"$VENV/bin/python" -m ipykernel install --user --name agentcore-demo --display-name "AgentCore demo (Python 3.13)"
echo "Registered kernel: AgentCore demo (Python 3.13)"
echo "In Cursor: Select Kernel -> Jupyter Kernel... -> AgentCore demo (Python 3.13)"
