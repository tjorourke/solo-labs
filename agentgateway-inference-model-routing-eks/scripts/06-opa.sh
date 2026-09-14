#!/usr/bin/env bash
# OPA as the decider: deploy it, load the Rego, and hand it the routing decision.
#
#   ./scripts/06-opa.sh
#
# Applies yaml/90 (OPA itself), builds the opa-policy ConfigMap from opa/routing.rego,
# then applies the extAuth policy and the x-model route. Optional: the lab works
# without it, and quick.sh does not run it.
#
# Switch away again with either of the other deciders:
#   kubectl apply -f yaml-oss/20-routing-policy.yaml          -f yaml-oss/30-httproute.yaml   # keyword
#   kubectl apply -f yaml-oss/80-semantic-router-extproc.yaml -f yaml-oss/81-httproute-vsr.yaml   # semantic
set -euo pipefail

# The lab root, so the script works from anywhere.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Cluster selection: current context by default, KUBE_CONTEXT to name one, or
# EKS_CLUSTER for the cloud case where the context name is an ARN nobody types.
. "$HERE/scripts/lib-context.sh"
resolve_ctx
kubectl() { command kubectl --context "$CTX" "$@"; }

NS=agentgateway-system
banner() { echo; echo "==> $*"; }

banner "the policy, from opa/routing.rego"
# Built from the file rather than pasted into a manifest, so there is one copy of the
# Rego. OPA reads the file once at start, hence the restart below on a re-run.
kubectl create configmap opa-policy -n "$NS" \
  --from-file=routing.rego="$HERE/opa/routing.rego" \
  --dry-run=client -o yaml | kubectl apply -f -

banner "OPA"
kubectl apply -f "$HERE/yaml/90-opa.yaml"
kubectl -n "$NS" rollout restart deploy/opa >/dev/null
kubectl -n "$NS" rollout status deploy/opa --timeout=180s

# OPA logs the rule path it serves at start. If the Rego failed to compile the pod
# would not be Ready, but say which rule is live anyway.
kubectl -n "$NS" logs deploy/opa --tail=50 | grep -o '"msg":"Starting gRPC server."[^}]*' | head -1 || true

banner "handing it the decision"
kubectl apply -f "$HERE/yaml-oss/91-opa-extauth-policy.yaml"
kubectl apply -f "$HERE/yaml-oss/30-httproute.yaml"

# Accepted and Attached matter, and so does the message. A policy whose extAuth cannot
# resolve the opa Service reports Accepted=True with the failure in the message.
banner "attachment status"
kubectl -n "$NS" get agentgatewaypolicy extract-model-internal \
  -o jsonpath='{range .status.ancestors[*]}{range .conditions[*]}{.type}={.status}  {.message}{"\n"}{end}{end}'

echo
echo "OPA now decides. Prove it with:  ./scripts/test-policy.sh"
