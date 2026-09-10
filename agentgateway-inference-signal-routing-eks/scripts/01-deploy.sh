#!/usr/bin/env bash
# Add the complexity signal and the decision that uses it.
#
#   ./scripts/01-deploy.sh
#
# Re-runs the model-routing lab's Helm release with one extra values file. Nothing else in the cluster
# changes: same gateway, same policy, same route, same backends, same models.
#
# PART1_DIR points at the model-routing lab, whose values file this overlays. Set it
# if the two labs are not siblings.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PART1_DIR="$(cd "${PART1_DIR:-$HERE/../agentgateway-inference-model-routing-eks}" 2>/dev/null && pwd || echo "${PART1_DIR:-}")"
BASE_VALUES="$PART1_DIR/yaml/70-semantic-router-values.yaml"

[ -f "$BASE_VALUES" ] || {
  echo "error: cannot find the model-routing lab's values at $BASE_VALUES" >&2
  echo "  set PART1_DIR=<path to the model-routing lab>" >&2
  exit 1
}

. "$HERE/scripts/lib-context.sh"
resolve_ctx
helm_() { helm --kube-context "$CTX" "$@"; }
kubectl() { command kubectl --context "$CTX" "$@"; }

VSR_VERSION="${VSR_VERSION:-0.3.0}"

echo "==> semantic router $VSR_VERSION, with the complexity signal"
# Both files, in order. The overlay carries the full decisions list because Helm replaces
# lists rather than merging them.
helm_ upgrade --install semantic-router \
  oci://ghcr.io/vllm-project/charts/semantic-router \
  -n agentgateway-system --version "$VSR_VERSION" \
  -f "$BASE_VALUES" \
  -f "$HERE/yaml/00-complexity-signal.yaml" \
  --wait --timeout 10m >/dev/null

kubectl -n agentgateway-system rollout status deploy/semantic-router --timeout=600s

echo
echo "==> what the router loaded"
POD="$(kubectl get pod -n agentgateway-system -l app.kubernetes.io/name=semantic-router \
        -o jsonpath='{.items[0].metadata.name}')"
# These two lines are the proof the signal is live rather than merely accepted. A config
# can validate, load, and still leave the classifier uninitialised.
kubectl -n agentgateway-system logs "$POD" | grep -o '"decisions":"[^"]*"' | head -1
kubectl -n agentgateway-system logs "$POD" | grep -oE 'complexity_(classifier_initialized|candidates_preloaded)' | sort -u | sed 's/^/  /'

echo
echo "done. Prove it with:  ./scripts/02-test-routing.sh"
