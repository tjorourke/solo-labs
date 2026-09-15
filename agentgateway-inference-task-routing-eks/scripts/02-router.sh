#!/usr/bin/env bash
# Step 1 of the flow: the router becomes a task classifier.
#
#   ./scripts/02-router.sh
#
# Re-runs the semantic router's Helm release with yaml/10-router-tasks.yaml, which replaces
# Part 3's config. The router now answers "what kind of task is this" with one of five
# labels, and nothing about models or places. It restarts to load the new signals; the
# classifier weights are already on its volume, so this takes a minute or two, not ten.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/scripts/lib.sh"
VSR_VERSION="${VSR_VERSION:-0.3.0}"
banner "semantic router $VSR_VERSION as a task classifier"
helm_ upgrade --install semantic-router oci://ghcr.io/vllm-project/charts/semantic-router \
  -n "$NS" --version "$VSR_VERSION" -f "$HERE/yaml/10-router-tasks.yaml" >/dev/null
kubectl -n "$NS" rollout restart deploy/semantic-router >/dev/null
kubectl -n "$NS" wait --for=condition=Available deploy/semantic-router --timeout=900s
sleep 5
banner "what it loaded"
POD="$(kubectl -n "$NS" get pod -l app.kubernetes.io/name=semantic-router --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')"
kubectl -n "$NS" logs "$POD" | grep -o '"decisions":"[^"]*"' | head -1
kubectl -n "$NS" logs "$POD" | grep -oE '"(embedding|keyword)[a-z_]*(initialized|loaded)"[^}]{0,80}' | head -4
echo
echo "Try it:  ./scripts/classify.sh \"Review this function for concurrency bugs.\""
echo "Next:    ./scripts/03-opa.sh"
