#!/usr/bin/env bash
# The four backends: two on the GPU, two frontier, and the two frontier keys.
#
#   OPENAI_API_KEY=... ANTHROPIC_API_KEY=... ./scripts/06-backends.sh
#
# The keys go into two Secrets in the gateway namespace, keyed Authorization, and only
# the backend that references a Secret ever uses it. The client, OPA, the router and the
# two vLLM servers never see either key.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/scripts/lib.sh"
: "${OPENAI_API_KEY:?export OPENAI_API_KEY first}"
: "${ANTHROPIC_API_KEY:?export ANTHROPIC_API_KEY first}"
banner "frontier provider secrets"
kubectl -n "$NS" create secret generic openai-secret    --from-literal=Authorization="Bearer $OPENAI_API_KEY"    --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NS" create secret generic anthropic-secret --from-literal=Authorization="Bearer $ANTHROPIC_API_KEY" --dry-run=client -o yaml | kubectl apply -f -
banner "backends"
kubectl apply -f "$HERE/yaml/10-selfhosted-backends.yaml" -f "$HERE/yaml/60-openai-backend.yaml" -f "$HERE/yaml/61-anthropic-backend.yaml"
kubectl -n "$NS" get agentgatewaybackends
echo
echo "Next: ./scripts/07-routing.sh"
