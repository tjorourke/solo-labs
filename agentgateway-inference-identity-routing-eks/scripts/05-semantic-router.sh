#!/usr/bin/env bash
# vLLM Semantic Router, pinned chart and image, configured for general against code.
#
#   ./scripts/05-semantic-router.sh
#
# First start downloads the classifier weights, a few GB, so allow ten minutes. It
# waits, then reads back the two lines that say the complexity signal actually started,
# because a config that validates and loads can still leave the classifier uninitialised.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/scripts/lib.sh"
VSR_VERSION="${VSR_VERSION:-0.3.0}"
banner "semantic router chart $VSR_VERSION"
helm_ upgrade --install semantic-router oci://ghcr.io/vllm-project/charts/semantic-router \
  -n "$NS" --version "$VSR_VERSION" -f "$HERE/yaml/40-semantic-router-values.yaml" >/dev/null
banner "waiting for it to download its classifier models"
# wait on Available rather than rollout status: a pod that sat Pending for a while (a volume
# that could not bind) leaves ProgressDeadlineExceeded on the Deployment, and rollout status
# then gives up at once even though the pod is now downloading.
kubectl -n "$NS" wait --for=condition=Available deploy/semantic-router --timeout=1800s
banner "did the signal start?"
POD="$(kubectl -n "$NS" get pod -l app.kubernetes.io/name=semantic-router -o jsonpath='{.items[0].metadata.name}')"
for _ in $(seq 1 30); do
  kubectl -n "$NS" logs "$POD" 2>/dev/null | grep -q complexity_candidates_preloaded && break; sleep 5
done
kubectl -n "$NS" logs "$POD" | grep -o '"decisions":"[^"]*"' | head -1
kubectl -n "$NS" logs "$POD" | grep -oE 'complexity_(classifier_initialized|candidates_preloaded)' | sort -u
echo
echo "Next: ./scripts/06-backends.sh"
