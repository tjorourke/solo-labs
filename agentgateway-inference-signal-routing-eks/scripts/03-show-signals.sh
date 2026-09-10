#!/usr/bin/env bash
# Show the complexity score behind each routing decision.
#
#   ./scripts/03-show-signals.sh
#
# 02-test-routing.sh proves where requests went. This shows why: the router logs one line
# per evaluation with both similarity scores, their difference, and the band it chose.
# Run it after a routing test, since it reads the log the test just produced.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/scripts/lib-context.sh"
resolve_ctx
kubectl() { command kubectl --context "$CTX" "$@"; }

POD="$(kubectl get pod -n agentgateway-system -l app.kubernetes.io/name=semantic-router \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[ -n "$POD" ] || { echo "error: no semantic-router pod. context: $CTX" >&2; exit 1; }

echo "Last 20 complexity evaluations, oldest first."
echo "signal = hard_score - easy_score, and threshold in yaml/00 is the line between them."
echo
kubectl -n agentgateway-system logs "$POD" --tail=2000 \
  | grep -oE "Complexity rule .[^\x27]*.: [^\"]*" \
  | tail -20 \
  | sed 's/^/  /'
