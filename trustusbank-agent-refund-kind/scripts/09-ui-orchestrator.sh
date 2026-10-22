#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
k -n bank create configmap bank-runtime-context \
  --from-file=sitecustomize.py="$LAB/agent/ui-runtime/sitecustomize.py" \
  --dry-run=client -o yaml | apply_stdin
k -n bank create configmap bank-legacy-runtime-context \
  --from-file=sitecustomize.py="$LAB/agent/legacy-runtime/sitecustomize.py" \
  --dry-run=client -o yaml | apply_stdin
apply "$LAB/yaml/agents.yaml"
apply "$LAB/yaml/operator-tools.yaml"
apply "$LAB/yaml/ui-orchestrator.yaml"
k -n bank rollout status deploy/ledger-agent --timeout=300s
k -n bank rollout status deploy/payments-assistant --timeout=300s
printf 'Enterprise UI: http://localhost:18380/ke/ (bob / password)\n'
