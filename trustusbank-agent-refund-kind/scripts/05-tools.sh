#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
k -n bank create configmap payments-mcp --from-file="$LAB/scripts/payments_mcp.py" --dry-run=client -o yaml | apply_stdin
existing=false
if k -n bank get deployment payments-mcp >/dev/null 2>&1; then existing=true; fi
apply "$LAB/yaml/payments.yaml"
apply "$LAB/yaml/audit.yaml"
if [[ "$existing" == true ]]; then restart_deployment bank payments-mcp; fi
k -n bank rollout status deploy/payments-mcp --timeout=300s
sleep 5
