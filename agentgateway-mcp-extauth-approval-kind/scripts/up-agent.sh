#!/usr/bin/env bash
# Optional shortcut for the "Bob asks the dba-agent" commands on the lab page.
# Run after scripts/up-enterprise.sh on the same cluster. No teardown.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
CLUSTER="${CLUSTER:-hitl-sts-part2}"
[[ "$CLUSTER" == hitl-sts-part2* ]] || { echo 'Use a separate hitl-sts-part2* cluster'; exit 1; }
CTX="kind-$CLUSTER"
KAGENT_VERSION="${KAGENT_VERSION:-0.10.6}"
hitl_kubectl(){ command kubectl --context "$CTX" "$@"; }
set +x
set -a; . "${SECRETS_FILE:-$HOME/.solo/secrets.env}" >/dev/null 2>&1; set +a
[[ -n "${ANTHROPIC_API_KEY:-}" ]] || { echo 'ANTHROPIC_API_KEY missing'; exit 1; }
K=oci://ghcr.io/kagent-dev/kagent/helm
helm --kube-context "$CTX" upgrade -i kagent-crds "$K/kagent-crds" -n kagent --create-namespace --version "$KAGENT_VERSION" --wait >/dev/null
# The key goes to Helm on stdin, so it is never in a file or on the command line.
printf '%s' "$ANTHROPIC_API_KEY" | helm --kube-context "$CTX" upgrade -i kagent "$K/kagent" -n kagent --version "$KAGENT_VERSION" \
  -f yaml-enterprise/kagent-values.yaml --set-file providers.anthropic.apiKey=/dev/stdin --wait --timeout 15m >/dev/null
printf '%s' "$ANTHROPIC_API_KEY" | hitl_kubectl -n mcp-extauth-demo create secret generic kagent-anthropic --from-file=ANTHROPIC_API_KEY=/dev/stdin --dry-run=client -o yaml | hitl_kubectl apply -f - >/dev/null
docker build -t dba-agent:dev src/dba-agent
kind load docker-image dba-agent:dev --name "$CLUSTER"
hitl_kubectl apply -f yaml-enterprise/kagent-dba-agent.yaml
hitl_kubectl -n mcp-extauth-demo wait --for=condition=Ready agent/dba-agent --timeout=300s
echo "kagent $KAGENT_VERSION and the BYO dba-agent are ready in $CTX. Cluster left running."
