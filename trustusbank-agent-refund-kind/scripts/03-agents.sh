#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
set +x
set -a
source "${SECRETS_FILE:-$HOME/code/solo/secrets/secrets-envs.sh}" >/dev/null 2>&1
set +a
: "${ANTHROPIC_API_KEY:?Anthropic key required by the reused native ADK agent}"
printf '%s' "$ANTHROPIC_API_KEY" | k -n bank create secret generic bank-model --from-file=ANTHROPIC_API_KEY=/dev/stdin --dry-run=client -o yaml | apply_stdin
bash "$LAB/scripts/10-kagent-enterprise.sh"
bash "$LAB/scripts/08-management.sh"
docker build -t trustusbank-orchestrator:8 "$LAB/agent"
docker build -t trustusbank-ledger:2 "$LAB/agent/native"
kind load docker-image --name trustusbank-lab trustusbank-orchestrator:8 trustusbank-ledger:2
bash "$LAB/scripts/09-ui-orchestrator.sh"
k -n bank patch authorizationpolicy ledger-workload --type=merge -p '{"spec":{"selector":{"matchLabels":{"app":null,"bank-agent":"ledger-agent"}}}}' --dry-run=server >/dev/null
k -n bank patch authorizationpolicy ledger-workload --type=merge -p '{"spec":{"selector":{"matchLabels":{"app":null,"bank-agent":"ledger-agent"}}}}'
sleep 5
restart_deployment bank orchestrator
restart_deployment bank ledger-agent
k -n bank rollout status deploy/orchestrator --timeout=240s
k -n bank rollout status deploy/ledger-agent --timeout=240s
bash "$LAB/scripts/capture-a2a.sh"
