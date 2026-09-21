#!/usr/bin/env bash
# Step 3 of the flow: the decision gateway, its backends, its policy and its route.
#
#   ANTHROPIC_API_KEY=... ./scripts/04-decision-gateway.sh
#
# The second hop. A Gateway of its own, ClusterIP; the three backends with the task labels
# aliased to the models they serve; a policy that verifies the token again and asks OPA with
# the body forwarded; and a route that reads the two headers OPA writes.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/scripts/lib.sh"
: "${ANTHROPIC_API_KEY:?export ANTHROPIC_API_KEY first}"
[ -f "$HERE/identity/jwks.json" ] || { echo "error: no identity/jwks.json. Run ./scripts/01-identity.sh" >&2; exit 1; }
banner "decision gateway"
kubectl apply -f "$HERE/yaml/30-decision-gateway.yaml"
kubectl wait --for=condition=Programmed gateway/decision-gateway -n "$NS" --timeout=180s
banner "backends: two on the GPU, one frontier"
kubectl -n "$NS" create secret generic anthropic-secret --from-literal=Authorization="Bearer $ANTHROPIC_API_KEY" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$HERE/yaml/40-backends.yaml"
banner "policy, with the lab JWKS inlined"
JWKS="$(tr -d '\n' < "$HERE/identity/jwks.json")"
AD_JWKS="$(tr -d '\n' < "$HERE/identity/agentdesktop-jwks.json")"
JWKS="$JWKS" AD_JWKS="$AD_JWKS" python3 - "$HERE/yaml/50-decide-policy.yaml.tmpl" "$HERE/yaml/50-decide-policy.yaml" <<'PY'
import os, sys
open(sys.argv[2], "w").write(
    open(sys.argv[1]).read()
    .replace("__JWKS__", os.environ["JWKS"])
    .replace("__AD_JWKS__", os.environ["AD_JWKS"])
)
PY
kubectl apply -f "$HERE/yaml/50-decide-policy.yaml"
banner "route"
kubectl apply -f "$HERE/yaml/60-decision-route.yaml"
sleep 3
banner "attachment status"
kubectl -n "$NS" get enterpriseagentgatewaypolicy decide -o jsonpath='{range .status.ancestors[*]}{range .conditions[*]}{.type}={.status}  {.message}{"\n"}{end}{end}'
kubectl -n "$NS" get httproute decision-routing -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status}{"\n"}{end}' | sort -u
echo
echo "Next: ./scripts/05-classify-gateway.sh"
