#!/usr/bin/env bash
# Put the model-routing lab's configuration back.
#
#   ./scripts/99-restore.sh
#
# Re-runs the Helm release with the model-routing lab's values alone, which drops the complexity signal
# and the decision that used it. Nothing else was ever changed, so there is nothing else
# to undo.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PART1_DIR="$(cd "${PART1_DIR:-$HERE/../agentgateway-inference-model-routing-eks}" 2>/dev/null && pwd || echo "${PART1_DIR:-}")"
BASE_VALUES="$PART1_DIR/yaml/70-semantic-router-values.yaml"

. "$HERE/scripts/lib-context.sh"
resolve_ctx
helm_() { helm --kube-context "$CTX" "$@"; }
kubectl() { command kubectl --context "$CTX" "$@"; }

helm_ upgrade --install semantic-router \
  oci://ghcr.io/vllm-project/charts/semantic-router \
  -n agentgateway-system --version "${VSR_VERSION:-0.3.0}" \
  -f "$BASE_VALUES" --wait --timeout 10m >/dev/null

POD="$(kubectl get pod -n agentgateway-system -l app.kubernetes.io/name=semantic-router \
        -o jsonpath='{.items[0].metadata.name}')"
echo "decisions now:"
kubectl -n agentgateway-system logs "$POD" | grep -o '"decisions":"[^"]*"' | head -1

# Read the state back rather than trusting the exit code. The complexity classifier
# should be gone, not merely unused.
if kubectl -n agentgateway-system logs "$POD" | grep -q complexity_classifier_initialized; then
  echo "WARNING: the complexity classifier is still initialised." >&2
  exit 1
fi
echo "complexity signal removed. The model-routing lab is back as it was."
echo "Confirm with that lab's own test:  $PART1_DIR/scripts/test-classifiers.sh"
