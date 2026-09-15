#!/usr/bin/env bash
# Put Part 1's routing back and take this part's objects off the cluster.
#
#   ./scripts/99-restore.sh
#
# Removes the identity policy, the four-rule route, the frontier backends and their keys,
# OPA and its ConfigMaps, then re-applies Part 1's backends, its semantic-router policy
# and route, and the router config Parts 1 and 2 use. The models, the gateway and the
# cluster are left alone. The GPU nodegroup stays at one node; Part 1's own scripts/gpu.sh
# up takes it back to two.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/scripts/lib.sh"
PART2_DIR="$(cd "${PART2_DIR:-$HERE/../agentgateway-inference-signal-routing-eks}" 2>/dev/null && pwd || echo "${PART2_DIR:-}")"
banner "this part's objects"
kubectl -n "$NS" delete agentgatewaypolicy identity-then-semantic --ignore-not-found
kubectl -n "$NS" delete httproute identity-routing --ignore-not-found
kubectl -n "$NS" delete agentgatewaybackend openai anthropic --ignore-not-found
kubectl -n "$NS" delete secret openai-secret anthropic-secret --ignore-not-found
kubectl delete -f "$HERE/yaml/20-opa.yaml" --ignore-not-found
kubectl -n "$NS" delete configmap opa-policy opa-entitlements --ignore-not-found
banner "Part 1's backends, policy and route (semantic mode)"
kubectl apply -f "$PART1_DIR/yaml-oss/10-backends.yaml" -f "$PART1_DIR/yaml-oss/80-semantic-router-extproc.yaml" -f "$PART1_DIR/yaml-oss/81-httproute-vsr.yaml"
banner "the router config Parts 1 and 2 use"
helm_ upgrade --install semantic-router oci://ghcr.io/vllm-project/charts/semantic-router \
  -n "$NS" --version "${VSR_VERSION:-0.3.0}" \
  -f "$PART1_DIR/yaml/70-semantic-router-values.yaml" \
  -f "$PART2_DIR/yaml/00-complexity-signal.yaml" --wait --timeout 10m >/dev/null
kubectl -n "$NS" rollout status deploy/semantic-router --timeout=600s
POD="$(kubectl -n "$NS" get pod -l app.kubernetes.io/name=semantic-router -o jsonpath='{.items[0].metadata.name}')"
kubectl -n "$NS" logs "$POD" | grep -o '"decisions":"[^"]*"' | head -1
echo
echo "Part 1 and Part 2 are back as they were. Confirm with:  $PART2_DIR/scripts/02-test-routing.sh"
