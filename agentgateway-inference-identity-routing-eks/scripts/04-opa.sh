#!/usr/bin/env bash
# The gateway, then OPA with its policy and its entitlement data.
#
#   ./scripts/04-opa.sh
#
# The Gateway is Part 1's own manifest, applied here so this part also works on a cluster
# Part 1 never touched. Re-run this script after editing opa/entitlements.json or
# opa/routing.rego: it rebuilds both ConfigMaps and restarts OPA so the change is live.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/scripts/lib.sh"
banner "gateway (Part 1's yaml/05-gateway.yaml)"
kubectl apply -f "$PART1_DIR/yaml/05-gateway.yaml"
kubectl wait --for=condition=Programmed gateway/model-gateway -n "$NS" --timeout=180s
banner "policy and data, from opa/"
kubectl create configmap opa-policy -n "$NS" --from-file=routing.rego="$HERE/opa/routing.rego" --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap opa-entitlements -n "$NS" --from-file=entitlements.json="$HERE/opa/entitlements.json" --dry-run=client -o yaml | kubectl apply -f -
banner "OPA"
kubectl apply -f "$HERE/yaml/20-opa.yaml"
kubectl -n "$NS" rollout restart deploy/opa >/dev/null
kubectl -n "$NS" rollout status deploy/opa --timeout=180s
echo
echo "Next: ./scripts/05-semantic-router.sh"
