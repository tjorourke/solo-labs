#!/usr/bin/env bash
# Revert GPU model routes to their original vllm backends after ./gpu-down.sh.
set -euo pipefail
CTX="${CTX:-arn:aws:eks:eu-west-2:253915036081:cluster/model-routing}"
NS=agentgateway-system
SAVE_DIR="$(cd "$(dirname "$0")" && pwd)/.gpu-snapshots"

if [ ! -d "$SAVE_DIR" ]; then
  echo "error: no snapshots found in $SAVE_DIR — run ./gpu-down.sh first" >&2
  exit 1
fi

echo "→ restoring routes from $SAVE_DIR"
for route in decision-routing kernwerk-decision kernwerk-private; do
  f="$SAVE_DIR/$route.yaml"
  if [ ! -f "$f" ]; then
    echo "  warning: no snapshot for $route, skipping" >&2
    continue
  fi
  kubectl --context "$CTX" apply -f "$f"
done

echo "✓ GPU routes restored. GPU nodes must be up for vLLM to serve requests."
