#!/usr/bin/env bash
# Step 2 of the flow: OPA with the routing table and the data checks.
#
#   ./scripts/03-opa.sh
#
# Three ConfigMaps: the plugin config (in yaml/20-opa.yaml), the policy from
# opa/routing.rego, and the data from opa/routing-data.json, which holds who may use which
# model pool, the task to pool and class table, and the markers that say "this is our
# code". Re-run after editing either file: it rebuilds both ConfigMaps and restarts OPA.
#
# Do not ship the ConfigMap. Kubernetes caps it at 1 MiB, every change is a rewrite and a
# restart, and it is readable by anything with access to the namespace. It is the smallest
# thing that proves the point; a real deployment feeds OPA the same data through its bundle
# API or a data source it queries at decision time, and nothing on the gateway changes.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/scripts/lib.sh"
banner "policy and data, from opa/"
kubectl create configmap opa-policy -n "$NS" --from-file=routing.rego="$HERE/opa/routing.rego" --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap opa-entitlements -n "$NS" --from-file=entitlements.json="$HERE/opa/routing-data.json" --dry-run=client -o yaml | kubectl apply -f -
banner "OPA"
kubectl apply -f "$HERE/yaml/20-opa.yaml"
kubectl -n "$NS" rollout restart deploy/opa >/dev/null
kubectl -n "$NS" rollout status deploy/opa --timeout=180s
banner "does the policy compile?"
kubectl -n "$NS" logs deploy/opa --tail=20 | { grep -iE "error|rego_" || echo "    no errors in the log"; }
echo
echo "Next: ./scripts/04-decision-gateway.sh"
