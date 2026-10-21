#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
set +x
set -a
source "${SECRETS_FILE:-$HOME/.solo/secrets.env}" >/dev/null 2>&1
set +a
: "${ANTHROPIC_API_KEY:?Anthropic key required by the reused native ADK agent}"
printf '%s' "$ANTHROPIC_API_KEY" | k -n bank create secret generic bank-model --from-file=ANTHROPIC_API_KEY=/dev/stdin --dry-run=client -o yaml | apply_stdin
docker exec trustusbank-lab-control-plane mkdir -p -m 0777 /var/local/trustusbank-kagent-db
apply "$LAB/yaml/kagent-storage.yaml"
R=oci://ghcr.io/kagent-dev/kagent/helm
helm --kube-context "$CTX" upgrade -i kagent-crds "$R/kagent-crds" -n kagent --create-namespace --version 0.10.0 --wait
helm template kagent "$R/kagent" -n kagent --version 0.10.0 -f "$LAB/yaml/kagent-values.yaml" --set controller.replicas=0 | k apply --dry-run=server -f - >/dev/null
helm --kube-context "$CTX" upgrade -i kagent "$R/kagent" -n kagent --version 0.10.0 -f "$LAB/yaml/kagent-values.yaml" --set controller.replicas=0 --wait --timeout=6m
k -n kagent rollout status deploy/kagent-postgresql --timeout=180s
helm template kagent "$R/kagent" -n kagent --version 0.10.0 -f "$LAB/yaml/kagent-values.yaml" --set controller.replicas=1 | k apply --dry-run=server -f - >/dev/null
helm --kube-context "$CTX" upgrade -i kagent "$R/kagent" -n kagent --version 0.10.0 -f "$LAB/yaml/kagent-values.yaml" --set controller.replicas=1 --wait --timeout=6m
docker build -t trustusbank-orchestrator:4 "$LAB/agent"
docker build -t trustusbank-ledger:2 "$LAB/agent/native"
kind load docker-image --name trustusbank-lab trustusbank-orchestrator:4 trustusbank-ledger:2
apply "$LAB/yaml/agents.yaml"
k -n bank patch authorizationpolicy ledger-workload --type=merge -p '{"spec":{"selector":{"matchLabels":{"app":null,"bank-agent":"ledger-agent"}}}}' --dry-run=server >/dev/null
k -n bank patch authorizationpolicy ledger-workload --type=merge -p '{"spec":{"selector":{"matchLabels":{"app":null,"bank-agent":"ledger-agent"}}}}'
sleep 5
k -n bank rollout restart deploy/orchestrator deploy/ledger-agent
k -n bank rollout status deploy/orchestrator --timeout=240s
k -n bank rollout status deploy/ledger-agent --timeout=240s
bash "$LAB/scripts/capture-a2a.sh"
