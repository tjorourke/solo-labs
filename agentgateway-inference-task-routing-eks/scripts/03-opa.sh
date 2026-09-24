#!/usr/bin/env bash
# Retained entrypoint: install the immediate audit transport, not an authoriser.
# Routing data is rendered into native AGW CEL by 04-decision-gateway.sh.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/scripts/lib.sh"
banner "audit transport"
kubectl create configmap routing-audit-policy -n "$NS" --from-file=routing.rego="$HERE/opa/routing.rego" --dry-run=client -o yaml | kubectl apply -f -
# Retain this data API for the console's agent registration flow. It is no longer
# mounted in OPA; the native policy is updated when an identity is registered.
kubectl create configmap opa-entitlements -n "$NS" --from-file=entitlements.json="$HERE/opa/routing-data.json" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$HERE/yaml/20-opa.yaml"
kubectl -n "$NS" rollout restart deploy/routing-audit >/dev/null
kubectl -n "$NS" rollout status deploy/routing-audit --timeout=180s
echo "Next: ./scripts/04-decision-gateway.sh"
