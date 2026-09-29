#!/usr/bin/env bash
# Demo console on http://localhost:8900
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
# console.env (gitignored, copied from console.env.example) holds the per-laptop
# settings: the model gateway and UI hostnames, and which context is the EKS cluster.
if [ -f "$HERE/console.env" ]; then set -a; . "$HERE/console.env"; set +a; fi
# Gateway decisions come from the task-routing cluster. Set MODEL_ROUTING_CONTEXT
# (or KUBE_CONTEXT) to its kubeconfig context name to choose it. Left unset, serve.py
# finds the context named model-routing, or ending in cluster/model-routing.
# kubectl's current context is never used, because it usually points at another lab.
KUBE_CONTEXT="${KUBE_CONTEXT:-${MODEL_ROUTING_CONTEXT:-${MODEL_ROUTING:-}}}"
if [ -n "$KUBE_CONTEXT" ]; then
  export KUBE_CONTEXT
else
  unset KUBE_CONTEXT
  # Read the list first: under pipefail, grep -q exiting on the first match kills
  # kubectl with SIGPIPE and the pipeline reads as "not found".
  CONTEXTS="$(kubectl config get-contexts -o name 2>/dev/null || true)"
  if ! grep -qE '(cluster/model-routing|^model-routing|^kind-model-routing)$' <<<"$CONTEXTS"; then
    echo "warning: no model-routing context in kubeconfig; Gateway decisions will be empty." >&2
    echo "         Set MODEL_ROUTING_CONTEXT in console.env to the EKS cluster's context name." >&2
  fi
fi
# A console left running from an earlier ./run.sh holds the port and serves the
# code it loaded at start, so stop it rather than refusing to start.
PORT="${DASHBOARD_PORT:-8900}"
OLD="$(lsof -nP -t -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true)"
if [ -n "$OLD" ]; then
  echo "stopping the console already on port $PORT (pid $(echo $OLD | tr '\n' ' '))"
  kill $OLD 2>/dev/null || true
  for _ in $(seq 20); do
    lsof -nP -t -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 || break
    sleep 0.5
  done
  if lsof -nP -t -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    kill -9 $OLD 2>/dev/null || true
    sleep 1
  fi
fi
exec python3 "$HERE/serve.py"
