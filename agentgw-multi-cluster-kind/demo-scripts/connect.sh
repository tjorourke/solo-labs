#!/usr/bin/env bash
# connect.sh — set the two cluster contexts and confirm the standup is peered.
# Source this (`. demo-scripts/connect.sh`) so CLUSTER1/CLUSTER2 stay exported
# for the rest of the notebook.
export CLUSTER1="${CLUSTER1:-kind-east-ag}"
export CLUSTER2="${CLUSTER2:-kind-west-ag}"
export PATH="$HOME/.gloo-mesh/bin:$PATH"

echo "east = $CLUSTER1   west = $CLUSTER2"
if istioctl --context "$CLUSTER1" multicluster check 2>&1 | grep -q "Peers Check: all clusters connected"; then
  echo "✓ clusters peered over HBONE"
else
  echo "✗ clusters not peered — heal it with ./demo-scripts/wake.sh" >&2
  echo "  (usually stale certs after the laptop slept; full rebuild = scripts/quick.sh)" >&2
fi
