#!/usr/bin/env bash
# Put Part 3 back and take this part's objects off the cluster.
#
#   ./scripts/99-restore.sh
#
# Removes the intake listener, the decision gateway, their policies and routes, and the
# classify policy and route on model-gateway, then re-applies Part 3's OPA policy and data,
# its backends, its policy and route, and its router config. The models and the cluster are
# left alone.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/scripts/lib.sh"
banner "this part's objects"
kubectl -n "$NS" delete enterpriseagentgatewaypolicy classify decide routing-outcome normalise-model --ignore-not-found
kubectl -n "$NS" delete httproute classify-then-decide decision-routing decision-denied intake-routing --ignore-not-found
kubectl -n "$NS" delete deployment/routing-audit service/routing-audit configmap/routing-audit-policy configmap/routing-audit-config --ignore-not-found
kubectl -n "$NS" delete gateway decision-gateway --ignore-not-found
kubectl -n "$NS" delete enterpriseagentgatewayparameters decision-gateway-params --ignore-not-found
banner "Part 3's OPA policy and data"
kubectl create configmap opa-policy -n "$NS" --from-file=routing.rego="$PART3_DIR/opa/routing.rego" --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap opa-entitlements -n "$NS" --from-file=entitlements.json="$PART3_DIR/opa/entitlements.json" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NS" rollout restart deploy/opa >/dev/null
kubectl -n "$NS" rollout status deploy/opa --timeout=180s
banner "Part 3's router config"
helm_ upgrade --install semantic-router oci://ghcr.io/vllm-project/charts/semantic-router \
  -n "$NS" --version "${VSR_VERSION:-0.3.0}" -f "$PART3_DIR/yaml/40-semantic-router-values.yaml" >/dev/null
kubectl -n "$NS" rollout restart deploy/semantic-router >/dev/null
kubectl -n "$NS" wait --for=condition=Available deploy/semantic-router --timeout=900s
banner "Part 3's backends, policy and route"
kubectl apply -f "$PART3_DIR/yaml/10-selfhosted-backends.yaml" -f "$PART3_DIR/yaml/60-openai-backend.yaml" -f "$PART3_DIR/yaml/61-anthropic-backend.yaml"
[ -f "$PART3_DIR/yaml/70-policy.yaml" ] && kubectl apply -f "$PART3_DIR/yaml/70-policy.yaml" || echo "    (render Part 3's policy with its scripts/07-routing.sh)"
kubectl apply -f "$PART3_DIR/yaml/80-httproute.yaml"
echo
echo "Part 3 is back. Confirm with:  $PART3_DIR/scripts/09-test-matrix.sh"
