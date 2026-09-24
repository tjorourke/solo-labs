#!/usr/bin/env bash
# Install the group-based routing policy. User membership stays with the IdP.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/scripts/lib.sh"
banner "routing policy"
kubectl create configmap routing-policy-code -n "$NS" --from-file=routing.rego="$HERE/opa/routing.rego" --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap routing-policy-data -n "$NS" --from-file=routing-data.json="$HERE/opa/routing-data.json" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$HERE/yaml/20-opa.yaml"
kubectl -n "$NS" rollout restart deploy/routing-policy >/dev/null
kubectl -n "$NS" rollout status deploy/routing-policy --timeout=180s
echo "Next: ./scripts/04-decision-gateway.sh"
