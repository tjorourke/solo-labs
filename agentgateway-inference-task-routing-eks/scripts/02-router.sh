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
# Wait for the NEW pod, not the Deployment: the old pod stays Available while the new one
# loads, so a wait on the Deployment returns at once and the log below is the old config.
for _ in $(seq 1 90); do
  n="$(kubectl -n "$NS" get pods -l app.kubernetes.io/name=semantic-router --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  r="$(kubectl -n "$NS" get pods -l app.kubernetes.io/name=semantic-router -o jsonpath='{.items[*].status.containerStatuses[0].ready}' 2>/dev/null)"
  [ "$n" = "1" ] && [ "$r" = "true" ] && break
  sleep 10
done
banner "what it loaded, read back from its log"
POD="$(kubectl -n "$NS" get pod -l app.kubernetes.io/name=semantic-router --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')"
# Three lines are the proof. The decisions list must name all six decisions in the file:
# Helm replaces lists rather than merging them, so a dropped decision loads without any
# error. The other two say the similarity banks were embedded and the classifier started,
# not merely that the config validated.
kubectl -n "$NS" logs "$POD" | grep -o '"decisions":"[^"]*"' | head -1
kubectl -n "$NS" logs "$POD" | grep -oE 'complexity_(classifier_initialized|candidates_preloaded)' | sort -u
echo
echo "Try it:  ./scripts/classify.sh \"Review this function for concurrency bugs.\""
echo "Next:    ./scripts/03-opa.sh"
