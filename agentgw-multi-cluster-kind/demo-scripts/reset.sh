#!/usr/bin/env bash
# reset.sh — remove the exercise workloads (leaves the platform standup intact).
set -Eeuo pipefail
CLUSTER1="${CLUSTER1:-kind-east-ag}"
CLUSTER2="${CLUSTER2:-kind-west-ag}"

pkill -f "port-forward.*gloo-mesh-ui" 2>/dev/null || true
for CTX in "$CLUSTER1" "$CLUSTER2"; do
  kubectl --context "$CTX" delete ns bookinfo ai-tools --ignore-not-found >/dev/null 2>&1 || true
done
kubectl --context "$CLUSTER1" delete ns ai-agents --ignore-not-found >/dev/null 2>&1 || true
echo "✓ exercise workloads removed (standup untouched)"
